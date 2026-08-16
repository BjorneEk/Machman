# Machman daemon protocol

MachmanAgent serves the full VM-management API on a unix domain socket:

```
$TMPDIR/<suite>/machman.sock       suite: $MACHMAN_SUITE_ID, else the process's bundle id with
                                   any .agent/.vmhost/.tests suffix stripped. A release build is
                                   com.gustaffranzen.Machman; a debug build is ...Machman.dev,
                                   so the two never share a socket or a VM library.
```

Sockets live in the runtime dir, deliberately **not** in the VM library: `sun_path` is 104 bytes
and a per-VM socket under the library path would exceed it, and the library is relocatable —
possibly onto a volume that cannot host a socket at all. The library itself defaults to
`~/Library/Application Support/<suite>/VMs` and is overridable via the `MachmanDataDir` user
default.

Mode 0600 — filesystem permissions are the auth boundary (same user only). One daemon per
socket: a second instance probes, finds a live listener, and refuses to start; a stale socket
file is reclaimed.

## Framing & envelope

Newline-delimited JSON-RPC 2.0: one JSON object per line, UTF-8, no raw newlines inside a
message. Requests carry an `id` (number or string); the daemon's event notifications carry
none. Void results are `{}`; a "nothing to return" result (e.g. no preview) is `null`.

```
--> {"jsonrpc":"2.0","id":1,"method":"machman.hello","params":{"client":"my-tui"}}
<-- {"id":1,"jsonrpc":"2.0","result":{"apiVersion":1,"daemonVersion":"1.0"}}
```

Clients should send `machman.hello` first and check `apiVersion` (currently `1`).

### Errors

```
<-- {"error":{"code":-32000,"data":{"machmanCode":"notFound"},"message":"no VM named 'x'"},"id":2,"jsonrpc":"2.0"}
```

Standard JSON-RPC codes (-32700 parse, -32600 invalid request, -32601 method not found,
-32602 invalid params) plus `-32000` for application errors. `data.machmanCode` is one of:
`notFound`, `alreadyExists`, `invalidState`, `macConflict`, `invalidArgument`,
`ioFailure`, `virtualizationFailure`, `installFailure`, `internalError`.

## Methods

| Method | Params | Result |
|---|---|---|
| `machman.hello` | `{client}` | `{apiVersion, daemonVersion}` |
| `host.capabilities` | — | `{maxCPUCount, minMemoryBytes, maxMemoryBytes, freeDiskBytes, uartUnavailable?, nestedVirtualizationSupported?, rosettaAvailability?, hostDisplayWidthPixels?, hostDisplayHeightPixels?, maxSerialPorts?}` (the optional tail is 1.0.4+) |
| `vm.list` | — | `[VMInfo]` |
| `vm.get` | `{name}` | `VMInfo` |
| `vm.create` | `{template?}` (optional params, 1.0.4+) | `VMInfo` (auto-named `new-VM<n>`; template `"blank"` = no devices, `"default"` = implied EFI device set (no disk), `"mac"` = mac-guest device set minus trackpad; absent = same as `"default"`) |
| `vm.delete` | `{name}` | `{}` (refused while running/installing) |
| `vm.rename` | `{name, newName}` | `{}` (refused while running) |
| `vm.copy` | `{name, newName?, diskIDs?, regenerateMAC?}` | `VMInfo` (refused while running; diskIDs = writable disks to carry, absent = all; regenerateMAC defaults true; the copy gets fresh machine identity and autostart off) |
| `vm.setHardware` | `{name, cpuCount?, memoryBytes?, nestedVirtualization?}` | `{}` (clamped to host + boot floors; nested virt is 1.0.4+, EFI/kernel boots on supporting hardware — skipped with a warning event otherwise) |
| `vm.regenerateMAC` | `{name}` | `VMInfo` (new random MAC persisted; refused while running) |
| `vm.disk.add` | `{name, disk: NewDisk}` | `{}` |
| `vm.disk.remove` | `{name, diskID}` | `{}` (owned files — storage raws and in-dir isos — are deleted with the entry; external files are only disconnected) |
| `vm.disk.import` | `{name, path}` | `VMInfo` (copies the file INTO the VM as an owned disk; format by magic bytes — ISO9660 → iso, qcow2 refused, else raw storage validated as a non-empty 512-multiple; emits `copyProgress`) |
| `vm.disk.promote` | `{name, diskID}` | `VMInfo` (copies a referenced external disk into the VM and swaps the entry in place, safe flag and position preserved; owned entries refuse with `invalidState`; emits `copyProgress`) |
| `vm.mount.add` | `{name, path, tag}` | `{}` |
| `vm.mount.remove` | `{name, mountID}` | `{}` |
| `vm.console.add` | `{name}` | `{}` (appends a virtio console port, guest `/dev/hvcN`; refused while running) |
| `vm.console.remove` | `{name}` | `{}` (pops the last console port; refused while running) |
| `vm.uart.add` | `{name}` | `{}` (appends a PL011 uart port, guest `/dev/ttyAMAN`; refused while running) |
| `vm.uart.remove` | `{name}` | `{}` (pops the last uart port; refused while running) |
| `vm.serial.setLogging` | `{name, kind: "console"\|"uart", index, config: SerialLogConfig}` | `{}` (retunes a port's file logging; applied live when the VM runs) |
| `vm.boot.setKernel` | `{name, enabled}` | `{}` (refused once macOS is installed) |
| `vm.boot.kernelSettings` | `{name, settings: {kernelPath, initrdPath?, commandLine}}` | `{}` |
| `vm.kernel.promote` | `{name, role: "kernel"\|"initramfs", sourcePath, tag}` | `VMInfo` (copies the file into `<vm>/kernels/<role>/<tag>/` as owned and points the role's field at it) |
| `vm.kernel.delete` | `{name, path}` | `VMInfo` (removes an owned kernel file — a path under `<vm>/kernels` — and clears any field referencing it) |
| `vm.setStartPolicy` | `{name, policy: {windowed, safe, autostart}}` | `{}` (`autostart && safe` → invalidArgument; autostart toggling installs/removes the VM's launchd agent; refused with `invalidState` while a safe run is hosted) |
| `vm.setSafety` | `{name, disks?: {id: bool}, mounts?: {id: bool}}` | `{}` (unknown id → notFound, nothing applies; while a safe run is hosted this edits the discardable shadow config) |
| `vm.start` | `{name, options?: {openWindow, force, safe}}` | `{}` (`macConflict` when a running VM already uses this VM's MAC, `force: true` overrides; `safe: true` runs a discardable shadow copy — see Safe runs below) |
| `vm.stop` | `{name, mode: "soft"\|"force"}` | `{}` (`soft` asks the guest via requestStop) |
| `vm.safeSave` | `{name, newName}` | `VMInfo` (promotes a RUNNING safe-run shadow to a real VM without interrupting the guest: the original flips to stopped, the new VM is running non-safe with fresh MAC/machine identity effective next boot; refused unless the VM is safe-hosted, or when newName is taken) |
| `vm.window.open` | `{name}` | `{}` (window appears from the daemon) |
| `vm.window.close` | `{name}` | `{}` (VM keeps running) |
| `vm.preview` | `{name, maxWidth?}` | `{jpegBase64}` or `null` |
| `vm.install.start` | `{name, source: {kind:"latest"} \| {kind:"ipsw", path}}` | `{}` |
| `vm.install.cancel` | `{name}` | `{}` |
| `vm.install.phase` | `{name}` | `InstallPhase` |
| `vm.device.add` | `{name, kind}` | `VMInfo` (1.0.4+; one device per kind; kind validity depends on boot mode — trackpad needs macOS, clipboard/rosetta refuse macOS; takes effect next boot) |
| `vm.device.remove` | `{name, kind}` | `VMInfo` (1.0.4+) |
| `vm.device.update` | `{name, device: DeviceInfo}` | `VMInfo` (1.0.4+; settings + enabled; `unavailable` ignored on input) |
| `vm.setEnabled` | `{name, disks?: {id: bool}, mounts?: {id: bool}, console?: {"<index>": bool}, uart?: {"<index>": bool}}` | `{}` (1.0.4+; `vm.setSafety` twin — unknown ids/indices refuse the whole batch; disabling a serial port renumbers later guest names, same as removing it) |
| `vm.kernel.setOverride` | `{name, path, commandLine?, overrideEnabled?}` | `VMInfo` (1.0.4+; per-owned-kernel-file cmdline override — replaces the VM command line while that file is active and the override is enabled; nil fields unchanged; dropped when the file is deleted) |
| `vm.disk.resize` | `{name, diskID, sizeBytes}` | `VMInfo` (1.0.4+; grow-only, owned storage disks, refused while running) |
| `vm.disk.rename` | `{name, diskID, newName}` | `VMInfo` (1.0.4+; owned storage disks — the backing file moves and the name-derived disk id changes; refused while running) |
| `vm.mount.setTag` | `{name, mountID, tag}` | `VMInfo` (1.0.4+; next-boot effect, tag must be unique on the VM) |
| `vm.kernel.rename` | `{name, path, tag}` | `VMInfo` (1.0.4+; owned kernel/initramfs files — the file moves to the new tag dir, kernel-boot references and the command-line override migrate; refused while running) |
| `vm.ssh.set` | `{name, integrationEnabled?, reverseApproved?}` | `VMInfo` (1.0.5+; nil fields unchanged; approving reverse access requires a reported reverse key; refused with `invalidState` during safe runs — host-side ~/.ssh effects must not track a discardable shadow) |
| `vm.ssh.refresh` | `{name}` | `{}` (1.0.5+; re-runs guest address discovery now; daemon-only — a vmhost refuses with `invalidState`) |
| `vm.ssh.reset` | `{name}` | `VMInfo` (1.0.5+; forgets all SSH state: config, the per-VM keypair, payload/report dirs, and host-side artifacts; refused during safe runs) |
| `host.operations` | — | `[OperationInfo]` (1.0.4+; live long-running operations for resync after reconnect — events have no replay; terminal states linger briefly) |
| `op.cancel` | `{id}` | `{}` (1.0.4+; `notFound` when finished/unknown, `invalidState` when the op can't cancel) |
| `host.installRosetta` | — | `{}` (1.0.4+; system-prompted install, reported as an operation; macOS 27 makes it a no-op success) |
| `events.subscribe` | — | `{}`; events then arrive on this connection |
| `daemon.retire` | — | `{}`; the daemon then stops serving and exits, leaving vmhosts (and their VMs) running for a successor to re-adopt. Only the daemon honors it; a vmhost refuses with `invalidState` |

## DTOs (abridged)

`VMInfo`: `{name, state, created, lastRan?, cpuCount, memoryBytes, macAddress?, disks:
[{id, type: "storage"|"image"|"iso", name?, path?, sizeBytes?, safe, owned?, enabled?}],
mounts: [{id, path, tag, safe, enabled?}], boot: {mode: "efi"|"linuxKernel"|"macOS", kernel?,
macInstallState?, minCPUCount?, minMemoryBytes?, ownedKernels?: [{role, tag, fileName, path,
overrideCommandLine?, overrideEnabled?}]}, windowOpen, startPolicy?:
{windowed, safe, autostart}, safeRun?, totalRuntimeSeconds?, consolePorts?, uartPorts?,
devices?, nestedVirtualization?, ssh?}`.

`devices` (1.0.4+) is an array of `DeviceInfo` `{kind, enabled, displayWidthPixels?,
displayHeightPixels?, displayPixelsPerInch?, sharesClipboard?, unavailable?}`; kinds:
`keyboard, trackpad, pointer, graphics, audioInput, audioOutput, network, clipboard,
entropy, rosetta, consoleLoginInstaller, sshInstaller` (treat unknown kinds as a device
you don't recognize). One device per kind. `consoleLoginInstaller` (additive, macOS boots
only): a read-only directory share carrying a generated script the guest runs to install
login prompts on the VM's consoles; older daemons preserve it in config and skip it at
boot with a warning. `sshInstaller` (1.0.5+, any boot mode): a read-only `SSHSetup` share
directory carrying a generated script that enables sshd in the guest and exchanges keys,
plus a writable `SSHReport` drop-box the guest reports back through; both names are
reserved mount tags.

`ssh` (1.0.5+) is `{guestUser?, guestHostname?, guestOS?, guestOSVersion?, guestHostKey?,
reverseState: "none"|"pending"|"approved", reversePublicKey?, integrationEnabled?,
lastReportAt?, lastRunStatus?, lastRunNote?, lastTransport?, scriptVersion?,
sshfsAvailable?, sshfsMountReady?, sshfsMountRoot?, alias?, identityFilePath?,
knownHostsPath?, setupSharePath?, hostUser?, address?, addressSource?: "dhcp"|"arp",
hostAddressForGuest?, reachability?: "unknown"|"waiting"|"ready"|"unreachable",
reachabilityDetail?, readySince?}` — absent entirely when SSH was never used (or from an
older daemon). The persisted half comes from the guest's install report:
`lastRunStatus` (`"ok"|"partial"|"failed"`, 1.0.6+) plus `lastRunNote` say what the last
run achieved and why it fell short, `lastTransport` (`"virtiofs"|"sshfs"|"local"`) how the
guest reached the payload, and `sshfs*` whether the guest can mount host folders over SSH
(usable only once `reverseState` is `approved` — compute that, don't cache it).
`alias`, `identityFilePath`, `knownHostsPath`, `setupSharePath` and `hostUser` are
server-resolved (clients must not derive library paths or naming policy): `alias` is the
effective `~/.ssh` name, `<vm>.machman` unless the VM's config overrides it, and
`setupSharePath` is the directory a guest without a virtiofs driver sshfs-mounts to reach
the payload. `address`/`addressSource`/`hostAddressForGuest`/`reachability*`/`readySince`
are a daemon overlay (like `safeRun`), present only while the VM runs — `reachability`
(1.0.6+) is this run's answer to "does the guest's sshd actually respond", never
persisted. Treat unknown `reverseState`/`reachability` strings as a state you don't
recognize.
Absent `devices` = an older daemon: the effective set is the implied per-boot default
(mac guests: keyboard, trackpad, pointer, graphics, audioInput, audioOutput, network;
EFI/kernel guests: keyboard, pointer, graphics, audioInput, audioOutput, network, clipboard).
`enabled` on disks/mounts/serial ports and devices: absent = enabled (older daemons never
emit it); disabled entries stay configured but are not attached at the next start.

`consolePorts`/`uartPorts` are arrays of `SerialPortInfo`
`{kind: "console"|"uart", index, guestDevice, logging: SerialLogConfig, socketPath?, logPath?,
mmioBase?, irq?, unavailable?}` (absent = an older daemon; count is the array length).
`socketPath` is the raw-byte data-plane unix socket, present only while the VM runs; `mmioBase`/
`irq` are populated for uart ports once platform info has been generated. `unavailable`
`{reason: "privateUARTGated"|"classUnavailable"|<unknown>, message, sinceOSVersion?}` is present
when a configured port cannot be attached on the daemon's host and is therefore left off the
running VM — currently only uart ports, which macOS gates behind the
`com.apple.private.virtualization` entitlement from `sinceOSVersion` (26.6.1) on; `message` is a
ready-to-display explanation. `SerialLogConfig` is
`{mode: "disabled"|"resetOnBoot"|"continuous", maxBytes?}` (default resetOnBoot, unlimited).

`disks[].owned?` is true when the backing file lives inside (and travels with) the VM's
directory — imports/promotes create owned disks; absent means an older daemon.
`disks[].path` is populated for every type — for `storage` it is the server-resolved absolute
path of the backing image (clients must not derive library paths). `safe` flags are the
safe-mode policy (clone-vs-attach for disks, omit-vs-mount for mounts); `safeRun` appears only
while a safe run impersonates the VM.

`state`: `stopped|starting|running|stopping|paused|error` — treat unknown strings as a state
you don't recognize, not an error. Dates are ISO 8601. New optional fields may appear at any
time; absent fields you rely on mean an older daemon.

`InstallPhase`: `{kind: idle|resolving|downloading|installing|installed|failed|interrupted,
version?, build?, message?, progress?: {fraction, completedBytes?, totalBytes?},
downloadStartedAt?}`.

## Events

After `events.subscribe`, the daemon pushes id-less notifications on the same connection:

```
<-- {"jsonrpc":"2.0","method":"event","params":{"state":"running","type":"stateChanged","vm":"Debian"}}
```

`params.type`: `stateChanged {vm, state}`, `listChanged` (re-fetch `vm.list`),
`installPhaseChanged {vm, phase}`, `log {vm?, level, message}`,
`copyProgress {vm, copiedBytes, totalBytes}` (compute ETA client-side; emitted by
`vm.copy` with vm = the copy being created, and by `vm.disk.import`, `vm.disk.promote`,
and safe-run shadow builds with vm = the affected VM). Unknown types: skip.

`operationChanged {op: OperationInfo}` (1.0.4+): a long-running operation started,
progressed, or reached a terminal state. `OperationInfo` = `{id, kind, vm?, label,
fraction?, completedBytes?, totalBytes?, startedAt, state, message?}` with open string sets
for `kind` (`copyVM, importDisk, promoteDisk, shadowBuild, safeSave, kernelImport, rosettaInstall`, …)
and `state` (`running, succeeded, failed, cancelled`). Terminal states are emitted once;
resync after reconnect with `host.operations`. `copyProgress` keeps being emitted in
parallel for older clients. ETA stays consumer math.

`sshChanged {vm}` (1.0.5+): the VM's SSH state moved (guest report ingested, address
discovery resolved, or switches flipped). No payload beyond the name — re-fetch the VM.

**1.0.4 compatibility note**: the persisted config format gained `devices`/`enabled`/
`kernelOverrides` keys. Older daemons decode configs fine but their next config save DROPS
those keys — which is why 1.0.4 bumps the desktop's daemon-version floor and triggers the
replace-older prompt. Wire-wise everything above is additive under `apiVersion` 1.

**1.0.5 compatibility note**: the persisted config format gained the `ssh` key (same
drop-on-rewrite hazard as 1.0.4), and `vm.ssh.*` answers `methodNotFound` on older
daemons/vmhosts — both are why 1.0.5 bumps the floor again. Wire-wise everything above
remains additive under `apiVersion` 1.

**1.0.6 compatibility note**: the `ssh` config sub-object gained keys (alias, last
address, last-run status, sshfs capability) with the same drop-on-rewrite hazard, and
generated installer payloads moved from `<vmdir>/` to `<vmdir>/share/` — an older daemon
regenerates them in the old place, so the two cannot share a library. Hence the floor
bump. Wire-wise everything above remains additive under `apiVersion` 1.

## Safe runs (invisible on the wire except `safeRun`)

`vm.start {safe: true}` clones the VM into a hidden shadow (safe disks → discardable
clones, unsafe disks → the real files, ISOs referenced, safe mounts omitted) and runs the
shadow AS the VM: name, events, socket, and window are all the real VM's, and the shadow is
deleted on stop (a clean stop copies last-ran and total-runtime back). The ONLY wire
evidence is `VMInfo.safeRun: true` while the run lives. `vm.setSafety` during a safe run
edits the discardable shadow; `vm.setStartPolicy` is refused. `vm.safeSave` turns the
running shadow into a real VM (see the method table); until the promoted VM reboots onto
its fresh MAC, starting the ORIGINAL requires `force` (macConflict). Safe runs survive
daemon restarts (the daemon re-attaches by matching the shadow's recorded vmhost pid
against the socket peer) and reset on host reboot.

## Per-VM host processes (invisible on the wire)

Every running VM lives in its own `MachmanVMHost` process, which serves this same protocol on
`$TMPDIR/<suite>/vm-<hash>.sock` (hashed because a VM name may be any length); MachmanAgent proxies
per-VM operations to it and re-emits its events.
Clients never need to know: the public socket remains the single entry point and nothing about
the protocol changes. Consequences you can observe: one VM crashing cannot take others (or the
daemon) down, and vmhosts outlive daemon restarts — a new MachmanAgent re-adopts them.

## What is deliberately NOT here

The VM display. `VZVirtualMachineView` cannot leave the daemon's process, so VM windows
are presented by MachmanAgent itself; clients only command them (`vm.window.*`) and poll
`vm.preview` for thumbnails.

Interactive serial text runs on a separate **data plane**, not the JSON-RPC control socket.
Each configured console/uart port is served by the VM's vmhost as a raw-byte
`AF_UNIX SOCK_STREAM` socket; the control plane only reports its `socketPath` (in
`SerialPortInfo`), and clients connect to it directly (e.g.
`socat -,raw,echo=0 unix-connect:<socketPath>`). The daemon never proxies the byte stream.

## Trying it by hand

```sh
# a debug build serves the .dev suite; omit for a release build
export MACHMAN_SUITE_ID=com.gustaffranzen.Machman.dev
python3 scripts/machman-smoke.py                 # hello + vm list
python3 scripts/machman-smoke.py watch           # stream events
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"vm.list"}' | nc -U "$TMPDIR$MACHMAN_SUITE_ID/machman.sock"
```
