# Machman daemon protocol

Machmand serves the full VM-management API on a unix domain socket:

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
| `host.capabilities` | — | `{maxCPUCount, minMemoryBytes, maxMemoryBytes, freeDiskBytes}` |
| `vm.list` | — | `[VMInfo]` |
| `vm.get` | `{name}` | `VMInfo` |
| `vm.create` | — | `VMInfo` (auto-named `new-VM<n>`) |
| `vm.delete` | `{name}` | `{}` (refused while running/installing) |
| `vm.rename` | `{name, newName}` | `{}` (refused while running) |
| `vm.setHardware` | `{name, cpuCount?, memoryBytes?}` | `{}` (clamped to host + boot floors) |
| `vm.regenerateMAC` | `{name}` | `VMInfo` (new random MAC persisted; refused while running) |
| `vm.disk.add` | `{name, disk: NewDisk}` | `{}` |
| `vm.disk.remove` | `{name, diskID}` | `{}` (storage disks: deletes the backing file) |
| `vm.mount.add` | `{name, path, tag}` | `{}` |
| `vm.mount.remove` | `{name, mountID}` | `{}` |
| `vm.boot.setKernel` | `{name, enabled}` | `{}` (refused once macOS is installed) |
| `vm.boot.kernelSettings` | `{name, settings: {kernelPath, initrdPath?, commandLine}}` | `{}` |
| `vm.setStartPolicy` | `{name, policy: {windowed, safe, autostart}}` | `{}` |
| `vm.setSafety` | `{name, disks?: {id: bool}, mounts?: {id: bool}}` | `{}` (unknown id → notFound, nothing applies; while a safe run is hosted this edits the discardable shadow config) |
| `vm.start` | `{name, options?: {openConsole, force}}` | `{}` (`macConflict` when a running VM already uses this VM's MAC; `force: true` overrides) |
| `vm.stop` | `{name, mode: "soft"\|"force"}` | `{}` (`soft` asks the guest via requestStop) |
| `vm.console.open` | `{name}` | `{}` (window appears from the daemon) |
| `vm.console.close` | `{name}` | `{}` (VM keeps running) |
| `vm.console.info` | `{name}` | `{logPath}` (file-backed hvc0 log; null for macOS guests) |
| `vm.preview` | `{name, maxWidth?}` | `{jpegBase64}` or `null` |
| `vm.install.start` | `{name, source: {kind:"latest"} \| {kind:"ipsw", path}}` | `{}` |
| `vm.install.cancel` | `{name}` | `{}` |
| `vm.install.phase` | `{name}` | `InstallPhase` |
| `events.subscribe` | — | `{}`; events then arrive on this connection |

## DTOs (abridged)

`VMInfo`: `{name, state, created, lastRan?, cpuCount, memoryBytes, macAddress?, disks:
[{id, type: "storage"|"image"|"iso", name?, path?, sizeBytes?, safe}], mounts:
[{id, path, tag, safe}], boot: {mode: "efi"|"linuxKernel"|"macOS", kernel?, macInstallState?,
minCPUCount?, minMemoryBytes?}, consoleLogPath?, consoleOpen, startPolicy?:
{windowed, safe, autostart}, safeRun?, totalRuntimeSeconds?}`.

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
`installPhaseChanged {vm, phase}`, `log {vm?, level, message}`. Unknown types: skip.

## Per-VM host processes (invisible on the wire)

Every running VM lives in its own `MachmanVMHost` process, which serves this same protocol on
`$TMPDIR/<suite>/vm-<hash>.sock` (hashed because a VM name may be any length); Machmand proxies
per-VM operations to it and re-emits its events.
Clients never need to know: the public socket remains the single entry point and nothing about
the protocol changes. Consequences you can observe: one VM crashing cannot take others (or the
daemon) down, and vmhosts outlive daemon restarts — a new Machmand re-adopts them.

## What is deliberately NOT here

The VM display. `VZVirtualMachineView` cannot leave the daemon's process, so console windows
are presented by Machmand itself; clients only command them (`vm.console.*`) and poll
`vm.preview` for thumbnails. Interactive text access for Linux guests is the serial console
(`vm.console.info` → follow the log file; a PTY option is planned with the CLI).

## Trying it by hand

```sh
# a debug build serves the .dev suite; omit for a release build
export MACHMAN_SUITE_ID=com.gustaffranzen.Machman.dev
python3 scripts/machman-smoke.py                 # hello + vm list
python3 scripts/machman-smoke.py watch           # stream events
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"vm.list"}' | nc -U "$TMPDIR$MACHMAN_SUITE_ID/machman.sock"
```
