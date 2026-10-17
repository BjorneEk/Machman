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
possibly onto a volume that cannot host a socket at all. The library is the `VMs` folder of
the data dir, which defaults to `~/Library/Application Support/<suite>`. The `MachmanDataDir`
user default overrides the data dir; MachmanAgent reads it from its own defaults domain
(`<suite>.agent`, e.g. `defaults write com.gustaffranzen.Machman.agent MachmanDataDir
/Volumes/Big/Machman`) and passes the result to every vmhost it spawns.

Mode 0600 — filesystem permissions are the auth boundary (same user only). One daemon per
socket: a second instance probes, finds a live listener, and refuses to start; a stale socket
file is reclaimed. Listeners refresh their socket's timestamps hourly, so the system's temp-dir
cleaner (which removes entries untouched for 3 days) never reaps a live one.

## Framing & envelope

Newline-delimited JSON-RPC 2.0: one JSON object per line, UTF-8, no raw newlines inside a
message. Requests carry an `id` (number or string); the daemon's event notifications carry
none. Void results are `{}`; a "nothing to return" result (e.g. no preview) is `null`.
A client line without an `id` is a notification and is never answered — not even with
method-not-found (1.0.8; older daemons wrongly replied with `"id":null`).

```
--> {"jsonrpc":"2.0","id":1,"method":"machman.hello","params":{"client":"my-tui"}}
<-- {"id":1,"jsonrpc":"2.0","result":{"apiVersion":1,"daemonVersion":"1.0"}}
```

Clients should send `machman.hello` first and check `apiVersion` (currently `1`).

Requests carry **client-side deadlines**: nothing on the wire expresses one, but every caller
should bound its wait and abandon the id on expiry (the Swift client defaults to 30 s, with
generous bounds for boot/copy-class calls). Abandoning is unilateral and safe by protocol
rule: a response whose id is no longer awaited is silently dropped, so a late reply from a
slow server is never misdelivered. A deadline expiring says nothing about the server — the
call may still complete server-side (watch events for the outcome); clients must not treat a
timeout as a dead connection. A dropped connection says as little about the calls in flight:
each may or may not have run, so re-read state after reconnecting.

Requests on one connection run concurrently: each is answered when it finishes, matched by
id, so replies can arrive out of order, and two requests in flight may take effect in either
order (a `vm.disk.add` and a `vm.start` sent back to back can boot without the disk). A client
that needs an order waits for one reply before sending the next request. An event a request
causes can arrive before or after that request's reply.

A client must keep reading: one that leaves the daemon's writes blocked for 10 s, or lets
32 MiB queue up (an event subscription it stopped draining), is disconnected.

### Errors

```
<-- {"error":{"code":-32000,"data":{"machmanCode":"notFound"},"message":"No VM named “x”"},"id":2,"jsonrpc":"2.0"}
```

Standard JSON-RPC codes (-32700 parse, -32600 invalid request, -32601 method not found,
-32602 invalid params) plus `-32000` for application errors. `data.machmanCode` is one of:
`notFound`, `alreadyExists`, `invalidState`, `macConflict`, `invalidArgument`,
`ioFailure`, `virtualizationFailure`, `installFailure`, `internalError`, `timeout`
(1.0.9+: the daemon's own bounded call to a vmhost got no reply — the vmhost is left
alone; its message names the deadline, e.g. "No answer within 30 seconds"; unknown codes decode as
`internalError`, so the list is additively extensible), `cancelled` (the user canceled what the
call was doing — a `vm.stop` or `op.cancel` while a safe start prepared its shadow; a never-mind
for clients, not a failure). The Swift client reads a -32601 "method not found" as `unsupported`
(never sent as a `machmanCode`: a daemon relaying one from an older vmhost answers -32601
itself), so it can fall back when an older daemon lacks a method. Messages are one sentence
for people to read; match on the code, never on the text, which a newer daemon may reword.

### Names

Every method that takes a new name checks it where it enters (`invalidArgument` with a
one-sentence reason; `alreadyExists` for a taken name). Names stored before a rule existed
keep working — nothing is rejected at load.

- VM, disk and mount names and kernel tags: not empty, no `/`, no leading `.`, no control
  characters (tab, line break …), at most 255 UTF-8 bytes (disk names 251: the file adds
  `.raw`).
- VM names also exclude `${` (ssh expands `${VAR}` in the key and pin paths that carry the
  name, with no escape).
- Mount tags also exclude `: \ * ? | < >` (Virtualization's shared-folder rule) and the
  reserved payload names (`alreadyExists`).
- Disk names and tags are trimmed. VM names with leading or trailing spaces are refused
  (clients trim): the daemon keys on the name as sent.

## Methods

| Method | Params | Result |
|---|---|---|
| `machman.hello` | `{client}` | `{apiVersion, daemonVersion}` |
| `host.capabilities` | — | `{maxCPUCount, minMemoryBytes, maxMemoryBytes, freeDiskBytes, uartUnavailable?, nestedVirtualizationSupported?, rosettaAvailability?, hostDisplayWidthPixels?, hostDisplayHeightPixels?, maxSerialPorts?}` (the optional tail is 1.0.4+) |
| `vm.list` | — | `[VMInfo]` |
| `vm.get` | `{name}` | `VMInfo` |
| `vm.create` | `{template?}` (optional params, 1.0.4+) | `VMInfo` (auto-named `new-VM<n>`; template `"blank"` = no devices, `"default"` = implied EFI device set (no disk), `"mac"` = mac-guest device set minus trackpad; absent = same as `"default"`; 1.0.12+: an unknown name answers `invalidArgument` and a malformed `template` (not a string) answers -32602 — older daemons read malformed params as absent) |
| `vm.delete` | `{name}` | `{}` (refused while running/installing, or while another VM uses a file in this VM's folder; a guest→Mac key that can't be removed from `~/.ssh/authorized_keys` is reported as a warning `log` event) |
| `vm.rename` | `{name, newName}` | `{}` (refused while running/installing, or while another VM uses a file in this VM's folder; `newName` follows the name rules) |
| `vm.copy` | `{name, newName?, diskIDs?, mountIDs?, regenerateMAC?}` | `VMInfo` (refused while running; `newName` follows the name rules; diskIDs = writable disks to carry, absent = all; mountIDs = mounts to carry by `MountInfo.id`, absent = all (1.0.11+; older daemons ignore it and carry all); regenerateMAC defaults true; the copy gets fresh machine identity, autostart off, no serial logs and no ssh keypair, serves guest setup at its first boot like a new guest, and a not-yet-installed Mac copies as `failed` "Duplicated before macOS was installed") |
| `vm.setHardware` | `{name, cpuCount?, memoryBytes?, nestedVirtualization?}` | `{}` (clamped to host + boot floors; nested virt is 1.0.4+, EFI/kernel boots on supporting hardware — skipped with a warning event otherwise) |
| `vm.regenerateMAC` | `{name}` | `VMInfo` (new random MAC persisted; refused while running) |
| `vm.disk.add` | `{name, disk: NewDisk}` | `{}` (a storage disk's name follows the name rules and must be new to the VM — an existing disk or file is never replaced; `sizeBytes` is a positive multiple of 512; an `image` or `iso` by reference passes `vm.disk.import`'s format check first — qcow2 refused, raw a non-empty 512-multiple — with `invalidArgument`, and a missing file is `notFound`; a file the VM already attaches — by any path, a link or its own storage raw included — is `alreadyExists`) |
| `vm.disk.remove` | `{name, diskID}` | `{}` (owned files — storage raws and in-dir isos — are deleted with the entry; external files are only disconnected; `invalidState` while the VM runs (1.0.8+) or while another VM uses the owned file) |
| `vm.disk.import` | `{name, path}` | `VMInfo` (copies the file INTO the VM as an owned disk; format by magic bytes — ISO9660 → iso, qcow2 refused, else raw storage validated as a non-empty 512-multiple; emits `copyProgress`) |
| `vm.disk.promote` | `{name, diskID}` | `VMInfo` (copies a referenced external disk into the VM and swaps the entry in place, safe flag and position preserved; owned entries refuse with `invalidState`, and so does a running VM (1.0.9+); emits `copyProgress`) |
| `vm.mount.add` | `{name, path, tag, kind?}` | `{}` (`tag` follows the mount-tag rules; `kind` (1.0.7+): `"virtiofs"` (default) rides the share device, `"sshfs"` is mounted by the guest over its SSH link; sshfs refused for macOS guests) |
| `vm.mount.remove` | `{name, mountID}` | `{}` |
| `vm.console.add` | `{name}` | `{}` (appends a virtio console port, guest `/dev/hvcN`; refused while running) |
| `vm.console.remove` | `{name}` | `{}` (pops the last console port; refused while running) |
| `vm.uart.add` | `{name}` | `{}` (appends a PL011 uart port, guest `/dev/ttyAMAN`; refused while running) |
| `vm.uart.remove` | `{name}` | `{}` (pops the last uart port; refused while running) |
| `vm.serial.setLogging` | `{name, kind: "console"\|"uart", index, config: SerialLogConfig}` | `{}` (retunes a port's file logging; applied live when the VM runs, appending to this boot's log — only a run's first open empties a `resetOnBoot` file; `maxBytes` above 1073741824 (1 GiB) → `invalidArgument`, unless it is the port's stored cap sent back unchanged) |
| `vm.boot.setKernel` | `{name, enabled}` | `{}` (refused once macOS is installed, and with `invalidState` when a newer Machman set the boot mode; switched off, the kernel draft `boot.kernel` stays while it holds a kernel or initramfs path or a command line, and a draft that holds nothing goes) |
| `vm.boot.kernelSettings` | `{name, settings: {kernelPath, initrdPath?, commandLine}}` | `{}` (replaces the whole draft; while kernel boot is off, settings that hold nothing — no paths, an empty `initrdPath` counting as none, and a blank command line — drop the draft) |
| `vm.kernel.promote` | `{name, role: "kernel"\|"initramfs", sourcePath, tag}` | `VMInfo` (copies the file into `<vm>/kernels/<role>/<tag>/` as owned and points the role's field at it; `tag` follows the name rules) |
| `vm.kernel.delete` | `{name, path}` | `VMInfo` (removes an owned kernel file — `path` must name one of the VM's listed owned files once `..` is resolved, else `notFound` — and clears any field referencing it; a draft left holding nothing while kernel boot is off goes) |
| `vm.setStartPolicy` | `{name, policy: {windowed, safe, autostart}}` | `{}` (`autostart && safe` → invalidArgument; autostart toggling installs/removes the VM's launchd agent; refused with `invalidState` while a safe run is hosted, and turning autostart on is refused with `invalidState` while another VM that starts at login shares one of its writable disk files or its MAC, as their configs on disk say) |
| `vm.setSafety` | `{name, disks?: {id: bool}, mounts?: {id: bool}}` | `{}` (unknown id → notFound, nothing applies; while a safe run is hosted this edits the discardable shadow config) |
| `vm.start` | `{name, options?: {openWindow, force, safe}}` | `{}` (the client applies the VM's `startPolicy` to `options` — see DTOs; `macConflict` when a running VM already uses this VM's MAC, or one still starting with it — the earlier start wins — and `force: true` overrides; `invalidState` when a running or starting VM has one of this VM's writable disk files attached — a disk switched off on a running VM stays attached until it stops — which `force` does not override and which is checked before the MAC, so a plain start meets it first; `invalidState` when a newer Machman set the VM's boot mode (`boot.mode` `"unknown"`); `safe: true` runs a discardable shadow copy — see Safe runs below; a vmhost left over from an earlier start takes the start or refuses it — see Per-VM host processes) |
| `vm.stop` | `{name, mode: "soft"\|"force"}` | `{}` (`soft` asks the guest via requestStop, and answers `invalidState` at once while the VM lists `unresponsive`; a vmhost that doesn't answer a `force` stop within 15 s is listed `unresponsive` and the stop answers `timeout` ("… isn’t answering, so it didn’t stop") — a plain stop never ends a vmhost process; a VM still preparing a safe run is canceled instead, see Safe runs) |
| `vm.process.end` | `{name}` | `{}` (ends the process of the VM's vmhost, so the VM stops at once — sent only after the user confirmed it, for a VM listed `unresponsive` or whose `force` stop answered `timeout`; `invalidState` while its vmhost answers ("… is answering again — use Force Stop"), while it is starting or stopped, or when no vmhost process can be found to end; a warning `log` event follows; an older daemon answers -32601, and the desktop and agent then send a plain `force` stop instead) |
| `vm.safeSave` | `{name, newName}` | `VMInfo` (promotes a RUNNING safe-run shadow to a real VM without interrupting the guest: the original flips to stopped, the new VM is running non-safe with fresh MAC/machine identity effective next boot; the disks the run wrote directly (the original's unsafe storage disks it attached, whatever their flags say now) move into the new VM's folder and the original keeps them as references; refused unless the VM is safe-hosted, or when newName is taken or breaks the name rules; `invalidState` when the library sits on another volume than its safe runs; like `vm.copy`, the saved VM forgets the last guest-setup run and serves the installer at its next boot, when its SSH keypair is re-minted) |
| `vm.window.open` | `{name}` | `{}` (the VM's vmhost shows its window) |
| `vm.window.close` | `{name}` | `{}` (VM keeps running) |
| `vm.preview` | `{name, maxWidth?}` | `{jpegBase64}` or `null` |
| `vm.install.start` | `{name, source: {kind:"latest"} \| {kind:"ipsw", path}}` | `{}` (refused with `invalidState` once macOS is installed, while that VM's install is already running, or when a newer Machman set its boot mode; a retry after a failed or cancelled install starts over) |
| `vm.install.cancel` | `{name}` | `{}` |
| `vm.install.phase` | `{name}` | `InstallPhase` |
| `vm.device.add` | `{name, kind}` | `VMInfo` (1.0.4+; one device per kind; kind validity depends on boot mode — trackpad needs macOS, clipboard/rosetta refuse macOS; takes effect next boot) |
| `vm.device.remove` | `{name, kind}` | `VMInfo` (1.0.4+; removing `guestSetup` from a running VM leaves its served share in place until the VM stops) |
| `vm.device.update` | `{name, device: DeviceInfo}` | `VMInfo` (1.0.4+; replaces the whole device: every setting comes from the request and an absent one is cleared — absent `systemKeyCapture` = off — so send back the `DeviceInfo` you read with only your change applied; a client that predates a field resets it (a 1.0.9 desktop editing the resolution turns `systemKeyCapture` off); `unavailable` ignored on input) |
| `vm.setEnabled` | `{name, disks?: {id: bool}, mounts?: {id: bool}, console?: {"<index>": bool}, uart?: {"<index>": bool}, devices?: {"<kind>": bool}}` | `{}` (1.0.4+; `vm.setSafety` twin — unknown ids/indices refuse the whole batch; disabling a serial port renumbers later guest names, same as removing it; `devices` 1.0.12+: next-boot effect like `vm.device.update`, a kind the VM doesn't have refuses the whole batch, older daemons ignore the key) |
| `vm.kernel.setOverride` | `{name, path, commandLine?, overrideEnabled?}` | `VMInfo` (1.0.4+; per-owned-kernel-file cmdline override — replaces the VM command line while that file is active and the override is enabled; nil fields unchanged; dropped when the file is deleted) |
| `vm.disk.resize` | `{name, diskID, sizeBytes}` | `VMInfo` (1.0.4+; grow-only, owned storage disks, refused while running; `sizeBytes` is a positive multiple of 512 like `vm.disk.add`'s — else `invalidArgument`) |
| `vm.disk.rename` | `{name, diskID, newName}` | `VMInfo` (1.0.4+; owned storage disks — the backing file moves and the name-derived disk id changes; `newName` follows the name rules; refused while running, or while another VM uses the file) |
| `vm.mount.setTag` | `{name, mountID, tag}` | `VMInfo` (1.0.4+; next-boot effect, tag must be unique on the VM and follow the mount-tag rules) |
| `vm.mount.setKind` | `{name, mountID, kind}` | `VMInfo` (1.0.7+; next-boot effect; `"virtiofs"`\|`"sshfs"`, sshfs refused for macOS guests) |
| `vm.kernel.rename` | `{name, path, tag}` | `VMInfo` (1.0.4+; owned kernel/initramfs files — the file moves to the new tag dir, kernel-boot references and the command-line override migrate; `tag` follows the name rules; refused while running) |
| `vm.ssh.set` | `{name, integrationEnabled?, reverseApproved?, alias?}` | `VMInfo` (1.0.5+; nil fields unchanged; `alias` (1.0.6+) renames the ~/.ssh entry and an EMPTY alias resets it to the default — the mapped `<vm>.machman`, see `SSHInfo.alias` (validated as an ssh_config Host name and refused when another VM already answers to it, in any letter case since ssh keys the host-key pin by the lowercased alias — as that VM's config on disk says, which a running VM's vmhost keeps current); approving reverse access requires a reported reverse key and installs its line in `~/.ssh/authorized_keys` first — a line the Mac refuses refuses the approval, with nothing recorded — and `reverseApproved: false` DENIES it (1.0.6+: the key stays on file, nothing is installed, and the state only returns to `pending` when the guest reports a different key); a deny, revoke or `vm.ssh.reset` whose line can't be removed is reported as a warning `log` event naming it; refused with `invalidState` during safe runs — host-side ~/.ssh effects must not track a discardable shadow) |
| `vm.ssh.refresh` | `{name}` | `{}` (1.0.5+; re-runs guest address discovery now; daemon-only — a vmhost refuses with `invalidState`) |
| `vm.ssh.reset` | `{name}` | `VMInfo` (1.0.5+; forgets all SSH state: config, the per-VM keypair, payload/report dirs, and host-side artifacts; refused during safe runs) |
| `vm.setup.reset` | `{name}` | `VMInfo` (1.0.7+; forgets the guest-setup report state (`setup` + the report drop-box); the guest keeps what the script installed — SSH state has its own reset) |
| `vm.setup.serve` | `{name, serve}` | `VMInfo` (1.0.7+, additive; persists `setup.reinstallRequested` — an installed guest serves the installer only while it is set. ON fills the pre-registered share dirs live for a running VM; OFF is deferred: content leaves with the run (teardown), never mid-run, and a start with serving off registers the two reserved dirs EMPTY. Never-installed guests always serve) |
| `host.operations` | — | `[OperationInfo]` (1.0.4+; live long-running operations for resync after reconnect — events have no replay; terminal states linger briefly) |
| `op.cancel` | `{id}` | `{}` (1.0.4+; `notFound` when finished/unknown, `invalidState` when the op can't cancel, or when no vmhost had it but one didn't answer within 3 s — the op may run there ("… is not responding — try again in a moment"); the daemon asks every vmhost at once) |
| `host.installRosetta` | — | `{}` (1.0.4+; system-prompted install, reported as an operation; macOS 27 makes it a no-op success) |
| `events.subscribe` | — | `{}`; events then arrive on this connection (1.0.12+: the subscription is in place before the reply) |
| `daemon.retire` | — | `{}`; the daemon then stops serving and exits, leaving vmhosts (and their VMs) running for a successor to re-adopt. Refused with `invalidState` while the daemon itself runs work that would die with it — a start, a copy, an import or promote into a stopped VM, a macOS install — naming it ("… is installing macOS — try again when it finishes"). Only the daemon honors it; a vmhost refuses with `invalidState` |

## DTOs (abridged)

`VMInfo`: `{name, state, created, lastRan?, cpuCount, memoryBytes, macAddress?, disks:
[{id, type: "storage"|"image"|"iso", name?, path?, sizeBytes?, safe, owned?, enabled?}],
mounts: [{id, path, tag, safe, enabled?, kind?, automounted?, automountedAt?}],
boot: {mode: "efi"|"linuxKernel"|"macOS"|"unknown", kernel?,
macInstallState?, minCPUCount?, minMemoryBytes?, ownedKernels?: [{role, tag, fileName, path,
overrideCommandLine?, overrideEnabled?}] (in every boot mode — a macOS VM keeps its kernel files)}, windowOpen, startPolicy?:
{windowed, safe, autostart}, safeRun?, totalRuntimeSeconds?, consolePorts?, uartPorts?,
devices?, nestedVirtualization?, ssh?, setup?, unresponsive?, outdatedHost?}`.

`startPolicy` is applied by the client: `vm.start` takes explicit options only, so a client
that sends a plain start without reading it starts every VM windowed and unsafe. A plain Start
sends `{openWindow: startPolicy.windowed, safe: startPolicy.safe}` (no `startPolicy`: windowed,
not safe); Start Headless sends `openWindow: false` with the policy's `safe`; Start Safe sends
`safe: true` with the policy's `openWindow` (MachmanUI's `StartIntent`; `scripts/machman-smoke.py
start` does the same).

`boot.mode` `"unknown"`: the VM's config carries a boot mode a newer Machman wrote. The daemon
keeps that mode as written through its saves and never boots it — `vm.start` answers
`invalidState` "A newer version of Machman set this VM’s boot mode".

`unresponsive` is a daemon overlay, like `safeRun`: `true` while the VM's vmhost misses its 3 s
answer deadline. The rest of the entry is then that vmhost's last answer (state `unknown` if it
never answered), and a `listChanged` follows when it answers again; absent otherwise.
`vm.list`, `vm.get` and `host.operations` never wait longer than that deadline per vmhost (a
stalled vmhost's operations are left out until it answers).

`outdatedHost` (1.0.12+) is a daemon overlay too: `true` while the VM runs under a vmhost older
than the daemon (one that outlived an update of the app). Its setting changes answer
`invalidState` ("Restart … to finish updating") until it restarts; stop, its window, preview
and `vm.safeSave` keep working. Absent otherwise.

`devices` (1.0.4+) is an array of `DeviceInfo` `{kind, enabled, displayWidthPixels?,
displayHeightPixels?, displayPixelsPerInch?, systemKeyCapture?, sharesClipboard?,
unavailable?}`; kinds:
`keyboard, trackpad, pointer, graphics, audioInput, audioOutput, network, clipboard,
entropy, rosetta, consoleLoginInstaller, sshInstaller, guestSetup` (treat unknown kinds
as a device you don't recognize, and send its `kind` back unchanged). One device per kind. `guestSetup` (1.0.7+, any boot
mode) is THE installer: a read-only `GuestSetup` share directory carrying one generated
script that sets up everything guest-side — console logins, kernel console output, SSH,
guest→host SSH, sshfs, and boot automounts — plus a writable `GuestReport` drop-box the
guest reports back through. It supersedes `consoleLoginInstaller` and `sshInstaller`:
1.0.7 daemons collapse those into one `guestSetup` on config load and MAP them onto it
in `vm.device.add`/`remove`, so old clients keep working; all five directory names
(`GuestSetup`, `GuestReport`, and the legacy `LoginInstaller`/`SSHSetup`/`SSHReport`)
are reserved mount tags. Guests mount the share at `/mnt/machman/share` (1.0.6+ —
virtiofs, or sshfs of `ssh.setupSharePath` where there is no driver, same path either
way); sshfs-kind host folders land under `/mnt/machman/mounts`, and the script's own
state lives at `/var/lib/machman/state.env` (Linux) or `/var/db/machman/state.env`
(BSDs, macOS), beside the copy of the script that refreshes the report at every boot
without reading the share.

`systemKeyCapture` (1.0.10+, graphics) is `"off"|"always"|"fullScreen"` (absent = off;
treat unknown values as off): the mode a run STARTS with for sending system shortcuts
(⌘Space, ⌘Tab…) to the guest. The run's own value lives in the VM's window (its menu and
⌃⌥⌘K) and is not on the wire. A value you don't recognize (a newer daemon's mode) must go
back verbatim in `vm.device.update`: the daemon keeps its stored mode for any value it
doesn't know, and serves a stored mode it doesn't know exactly as stored (1.0.10 daemons
served it as `"unknown"`).

`ssh` (1.0.5+) is `{configured?, guestUser?, guestHostname?, guestOS?, guestOSVersion?, guestHostKey?,
reverseState: "none"|"pending"|"approved"|"denied", reversePublicKey?, integrationEnabled?,
lastReportAt?, lastRunStatus?, lastRunNote?, lastTransport?, scriptVersion?,
sshfsAvailable?, sshfsMountReady?, sshfsMountRoot?, alias?, identityFilePath?,
knownHostsPath?, setupSharePath?, hostUser?, address?, addressSource?: "dhcp"|"arp"|"report",
hostAddressForGuest?, reachability?: "unknown"|"waiting"|"ready"|"unreachable",
reachabilityDetail?, readySince?}` — absent entirely when SSH was never used (or from an
older daemon). `configured` (1.0.6+) is true when SSH is part of that VM — state on
file, or the installer attached — and is set only by the process that owns the config:
a running VM has a discovered address whether or not anyone asked for SSH, so a
non-nil `ssh` alone does NOT mean SSH is set up there. The persisted half comes from
the guest's install report:
`lastRunStatus` (`"ok"|"partial"|"failed"`, 1.0.6+) plus `lastRunNote` say what the last
run achieved and why it fell short, `lastTransport` (`"virtiofs"|"sshfs"|"local"`) how the
guest reached the payload, and `sshfs*` whether the guest can mount host folders over SSH
(usable only once `reverseState` is `approved` — compute that, don't cache it).
`alias`, `identityFilePath`, `knownHostsPath`, `setupSharePath` and `hostUser` are
server-resolved (clients must not derive library paths or naming policy): `alias` is the
effective `~/.ssh` name: the VM's own if set, otherwise the VM name mapped into the alias
charset plus `.machman` (`dev copy` → `dev-copy.machman`). When that default is already
another VM's alias, the VM taking the name stores a numbered one (`dev-copy-2.machman`),
which no other VM's change moves.
`setupSharePath` is the directory a guest without a virtiofs driver sshfs-mounts to reach
the payload: the rename-stable link in the library (`<library>/.machman-shares/<marker>`,
which carries no VM name) once a start has pointed it, the VM's own share before that. The
setup script's boot-time sshfs mount of the share goes through the same link. `address`/`addressSource`/`hostAddressForGuest`/`reachability*`/`readySince`
are a daemon overlay (like `safeRun`), present only while the VM runs — `reachability`
(1.0.6+) is this run's answer to "does the guest's sshd actually respond", never
persisted; `unreachable` means no answer on port 22, or (after the first two minutes) no
address found for the VM's MAC, and `reachabilityDetail` says which. `hostAddressForGuest`
is this Mac's own address on the interface whose subnet holds the guest's address, absent
when none does (never a guessed `.1`). Treat
unknown `reverseState`/`reachability` strings as a state you don't recognize.
`setup` (1.0.7+) is `{installed?, guestOS?, guestOSFamily?, guestOSVersion?,
guestInit?, lastReportAt?, scriptVersion?, currentScriptVersion?, lastRunStatus?,
lastRunNote?, lastTransport?, errors?: [{step, message}], notes?: [{step, message}],
features?: [{id, available, reason?, configured, detail?}], consoles?: [{device, login,
kernelConsole?}], automounts?: [{kind, target, path}], reinstallRequested?}` — the
unified installer's report, absent when the installer was never used (or from an older
daemon). `notes` (additive) are informational lines from the last run — a repair it made,
a boot-time refresh that will not run — never failures; absent when there are none.
`reinstallRequested` (additive) mirrors `vm.setup.serve`. Feature `id`s are plain strings
(`console, kernelConsole, ssh, reverseSSH, sshfs, virtiofsAutomount, sshfsAutomount` —
render unknown ids verbatim), `login` is `active|active-auto|configured|none|missing`,
and automount `kind` is a mount kind. `currentScriptVersion` is the script version the
serving app ships (server-resolved) — greater than `scriptVersion` means a re-run
updates the guest. `mounts[].kind` (1.0.7+, `"virtiofs"` when absent) says how a mount
reaches the guest; `mounts[].automounted` reflects the report (the one share automount
covers every virtiofs mount; sshfs mounts match by tag), and `mounts[].automountedAt`
(additive) is the guest directory it lands at. `consolePorts[].guestName` (additive) is
the device name the GUEST reported for the port via the setup run (`ttyV0.0`, `hvc0`) —
`guestDevice` stays the boot-mode guess; clients should prefer `guestName` when present.

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
`{mode: "disabled"|"resetOnBoot"|"continuous", maxBytes?}` (default resetOnBoot, unlimited;
`maxBytes` 0 or absent = unlimited, at most 1073741824). A mode a daemon doesn't know (a newer
Machman's) is kept as written through its saves and logs like resetOnBoot there.

`disks[].owned?` is true when the backing file lives inside (and travels with) the VM's
directory — imports/promotes create owned disks; absent means an older daemon.
`disks[].path` is populated for every type — for `storage` it is the server-resolved absolute
path of the backing image (clients must not derive library paths). `safe` flags are the
safe-mode policy (clone-vs-attach for disks, omit-vs-mount for mounts); `safeRun` appears only
while a safe run impersonates the VM.

`state`: `stopped|starting|running|stopping|paused|error` — treat unknown strings as a state
you don't recognize, not an error. The same tolerance applies to every closed string set in
this document (1.0.8) — `disks[].type`, `boot.mode`, `macInstallState.kind`,
`ownedKernels[].role`, serial-port `kind`, …: new values may appear as the daemon grows, so
render them as "unknown", never fail the payload. The daemon refuses values it doesn't know
in requests: an unknown value of one of these sets answers `invalidArgument`, while
`vm.stop`'s `mode` is strict and an unknown one answers -32602 invalid params. Dates are
ISO 8601. New optional fields may appear at any
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

The daemon passes each event a vmhost emits on in the line the vmhost sent it (1.0.12+), so
event types and fields the daemon itself doesn't know reach clients unchanged; older daemons
re-encoded them, which cut an unknown type down to `{"type"}`. The `log` events a vmhost
emits while its VM boots (a serial port it could not attach, a start without a window) reach
subscribers too (1.0.12+; older daemons subscribed to a vmhost only after its boot, so they
reached nobody). A freshly spawned vmhost's own state and list changes from before its start
returns are not passed on: the VM lists as `starting` until then — the daemon says
`stateChanged` `starting` once the start's checks pass (1.0.12+), and `stateChanged`
`stopped` before the `listChanged` of a start that fails after that — and then the daemon
announces the run with `stateChanged` `running` followed by `listChanged` (1.0.12+; older
daemons sent only the `listChanged`). The vmhost's own `running` may still follow just
after; a repeated state changes nothing.

`operationChanged {op: OperationInfo}` (1.0.4+): a long-running operation started,
progressed, or reached a terminal state. `OperationInfo` = `{id, kind, vm?, label,
fraction?, completedBytes?, totalBytes?, startedAt, state, message?, cancellable?}` with open
string sets for `kind` (`copyVM, importDisk, promoteDisk, shadowBuild, safeSave, kernelImport, rosettaInstall`, …)
and `state` (`running, succeeded, failed, cancelled`). `cancellable` (1.0.12+, additive) is
false when `op.cancel` would refuse with `invalidState`; absent from older daemons, which
clients treat as cancellable. Terminal states are emitted once;
resync after reconnect with `host.operations`. `copyProgress` keeps being emitted in
parallel for older clients. ETA stays consumer math. `host.operations` keeps terminal states
listed for about 10 s; a resyncing client ages them out as it would after the terminal event.

`sshChanged {vm}` (1.0.5+): the VM's SSH state moved (guest report ingested, address
discovery resolved, or switches flipped). No payload beyond the name — re-fetch the VM.

`setupChanged {vm}` (1.0.7+): the VM's guest-setup state moved (report ingested or reset).
No payload beyond the name — re-fetch the VM.

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

**1.0.7 compatibility note**: the two installer devices collapse into `guestSetup` —
configs migrate on load, so an older daemon neither understands the migrated kind nor
keeps the new `setup` sub-object and per-mount `kind` through its rewrite, and it would
regenerate the superseded `LoginInstaller`/`SSHSetup`/`SSHReport` payload dirs beside the
new `GuestSetup`/`GuestReport` ones. Hence the floor bump. Wire-wise everything above
remains additive under `apiVersion` 1 (`vm.mount.setKind`, `vm.setup.reset`, `vm.setup.serve`,
`setupChanged`, `VMInfo.setup`, `mounts[].kind/automounted`).

Payload directories are EPHEMERAL (1.0.7): written at VM start (and on attaching the
installer to a running VM), removed at VM stop after the final report ingest, and swept
at daemon startup for non-hosted VMs — a stopped VM's share holds no payload, so a stale
script from an older build cannot outlive the run that served it.

**1.0.8 compatibility note**: `vm.disk.remove` refuses while the VM runs (an older daemon
still unlinks the live attachment's backing file), notifications are never answered, and the
closed string sets decode unknown values tolerantly. Hence the floor bump.

**1.0.9 compatibility note**: `vm.disk.promote` refuses while the VM runs — an older daemon
still copies the image under the live attachment's writes and rewires the config beneath it,
so the next boot silently switches disks. Hence the floor bump; the `timeout` error code is
additive.

**1.0.10 compatibility note**: the graphics device gained `systemKeyCapture`. An older daemon
drops it on its next config rewrite and its vmhosts never apply it. Hence the floor bump.

**1.0.11 compatibility note**: `vm.safeSave` moves the disks a safe run wrote directly into
the saved VM and rewrites the original to reference them. An older daemon never reloads the
original, so its stale copy can be saved over the rewrite, and it lacks the refusals around
the save. Hence the floor bump; `vm.copy mountIDs` and `setup.notes` are additive.

**1.0.12 compatibility note**: `vm.setEnabled` gained `devices` (an older daemon ignores the
key, so a batch toggle silently skips devices), and the daemon refuses setting changes on VMs
still run by an older vmhost (`outdatedHost`), which is why the vmhost floor is the daemon's
own version. Hence the floor bump; the other 1.0.12 changes above are additive.

## Safe runs (invisible on the wire except `safeRun`)

`vm.start {safe: true}` clones the VM into a hidden shadow (safe disks → discardable
clones, unsafe disks → the real files, ISOs referenced, safe mounts omitted; every entry
keeps its enabled flag, so a disabled disk stays unattached) and runs the
shadow AS the VM: name, events, socket, and window are all the real VM's, and the shadow is
deleted on stop (a clean stop copies last-ran and total-runtime back). The ONLY wire
evidence is `VMInfo.safeRun: true` while the run lives. `vm.setSafety` during a safe run
edits the discardable shadow; `vm.setStartPolicy` is refused. `vm.safeSave` turns the
running shadow into a real VM (see the method table). The disks the run attached directly
(switching one off mid-run does not detach it) move into the saved VM's folder as its own;
the original lists them as references into that folder, so the saved VM cannot be deleted
or renamed, nor those disks removed or renamed, while the original uses them. A save that
fails is undone; if the saved folder or a moved disk cannot go back, the saved VM stays in
the library with a machine identity of its own, both VMs' configs say where each disk is,
and the daemon lists it at once. Until the promoted VM reboots onto its fresh MAC, starting
the ORIGINAL requires `force` (macConflict). Safe runs survive
daemon restarts (the daemon re-attaches by matching the shadow's recorded vmhost pid
against the socket peer) and reset on host reboot. Building the shadow is a `shadowBuild`
operation that `op.cancel` stops, and so does `vm.stop` in either mode (nothing runs yet); the
start then answers `cancelled` ("The safe run was canceled"). A start
that fails after the VM listed as `starting` is followed by a `listChanged`.

## Per-VM host processes (invisible on the wire)

Every running VM lives in its own `MachmanVMHost` process, which serves this same protocol on
`$TMPDIR/<suite>/vm-<hash>.sock` (hashed because a VM name may be any length); MachmanAgent proxies
per-VM operations to it and passes its events on as sent. The hash is of the VM's CURRENT name: after
`vm.safeSave` the run answers on the saved VM's path. A vmhost answers `machman.hello` with its
own bundle version plus `-vmhost` (1.0.12+; earlier ones echoed the spawning daemon's version,
or `dev` when a launch agent started them); one older than the daemon lists `outdatedHost`.
Clients never need to know: the public socket remains the single entry point and nothing about
the protocol changes. Consequences you can observe: one VM crashing cannot take others (or the
daemon) down, and vmhosts outlive daemon restarts — a new MachmanAgent re-adopts them. A dropped
connection to a vmhost that is still running is re-established — meanwhile the VM lists
`unresponsive`; only the vmhost's exit ends the run (and discards a safe run's shadow).

While a start is in flight (the vmhost's spawn window, a safe run's shadow build) the VM lists
as `starting`, and most of its per-VM calls refuse with `invalidState`, saying the VM is
starting; `vm.preview` answers `null`. Whole-VM edits (rename, copy, delete, MAC, disk
files, serial ports, kernel files, macOS install) also refuse while any vmhost answers on the
VM's socket, adopted by this daemon or not; one exiting after its VM stopped is waited out for
up to 3 s first, then "… is still shutting down — try again in a moment". Any per-VM call that
meets a vmhost on its way out (its VM stopped, or its connection dropped) waits for it the same
way, then goes to whatever owns the VM; one whose connection dropped and that neither comes back
nor exits answers "… is not responding — try again in a moment". A vmhost still draining an
import into its stopped VM is not waited for: per-VM calls go to it, and whole-VM edits refuse
at once with "… is importing a disk — try again when it finishes". A vmhost the daemon has not
adopted yet (busy when the daemon started, or started by a launch agent) is adopted on its VM's
next per-VM call or list; until then the VM lists with state `unknown`, plus `unresponsive` once
an adoption failed (the first failure is followed by a `listChanged`; from then on the daemon
asks it again every 5 s, not on each list). A vmhost that never accepts (frozen) still counts as
running while it lives and listens on the VM's socket, even once that socket refuses
connections.
`vm.start` adopts every such vmhost first (one whose adoption already failed is not asked
again), so its MAC and shared-disk checks see their VMs; one that can't be adopted counts with
its config's MAC and every disk it may have attached.

While a copy writes into a VM's folder or reads it whole — `vm.disk.import`, `vm.disk.promote`,
`vm.kernel.promote` (whether the daemon or the VM's vmhost does the copy), `vm.copy` of it —
`vm.start` and the whole-VM edits answer `invalidState` ("… is importing a disk — try again
when it finishes"; "… is promoting a disk", "… is importing a kernel file", "… is being
copied"). Imports and promotes into one VM may run side by side; a `vm.copy` runs alone.

`vm.start` asks a vmhost the daemon already holds for the VM before spawning one. A running
VM answers `invalidState` ("… is already running"). An idle host — spawned for a start that
was never forwarded because its daemon died in between; it exits on its own after 3 minutes —
runs this start, MAC check included; a safe start there answers `invalidState` ("… is still
prepared from an earlier start — start it normally, or wait up to 3 minutes to start it safe"),
since that host runs the real VM, never a shadow. An idle host older than the daemon (1.0.12+)
is ended instead and the start spawns a current one, so the run does not start locked by
`outdatedHost`; one the daemon has no process to end by still runs the start, locked. An idle
host a safe start spawned serves that run's shadow, so a plain start ends it and spawns a fresh
one; if it can't be ended the start answers `invalidState` ("… is still prepared from an earlier
safe start — wait up to 3 minutes, then start it again").
A host whose VM just stopped is exiting — once an operation it runs for that VM (an import, a
kernel promote) has finished: the
start waits up to 3 s for it to go and then starts normally; if the host is still there, the
start answers `invalidState` ("… is still shutting down — try again in a moment"). A host that
misses its answer deadline answers `invalidState` ("… is not responding — try again in a
moment"), as does every per-VM call whose vmhost can't be reached or adopted. A vmhost
answering on one VM's socket for another — a run an older vmhost saved as a new VM — is adopted
as the VM it serves, and starting the original answers `invalidState` ("… saved from …, still
runs on its socket — stop … before starting …").

## What is deliberately NOT here

The VM display. `VZVirtualMachineView` cannot leave the process that runs the VM, so each
VM's window is presented by its vmhost; clients only command it (`vm.window.*`) and poll
`vm.preview` for thumbnails.

Interactive serial text runs on a separate **data plane**, not the JSON-RPC control socket.
Each configured console/uart port is served by the VM's vmhost as a raw-byte
`AF_UNIX SOCK_STREAM` socket; the control plane only reports its `socketPath` (in
`SerialPortInfo`), and clients connect to it directly (e.g.
`socat -,raw,echo=0 unix-connect:<socketPath>`). The daemon never proxies the byte stream.
A port's `socketPath` belongs to the run: every start gets new paths, and a run saved as a new
VM keeps serving its ports at theirs — always read it from `SerialPortInfo`, never derive it.
Input for a guest that is not reading its port waits in order, up to 64 KiB beyond the pipe's
own buffer; past that, new input is dropped (logged once), and the port keeps serving every
client.

## Trying it by hand

```sh
# a debug build serves the .dev suite; omit for a release build
export MACHMAN_SUITE_ID=com.gustaffranzen.Machman.dev
python3 scripts/machman-smoke.py                 # hello + vm list
python3 scripts/machman-smoke.py watch           # stream events
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"vm.list"}' | nc -U "$TMPDIR$MACHMAN_SUITE_ID/machman.sock"
```
