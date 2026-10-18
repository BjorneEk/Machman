# Machman daemon protocol

MachmanAgent, the menu-bar daemon, serves the whole VM-management API as JSON-RPC 2.0 over a
unix socket. Machman Desktop is one client of it; any program that can write a line of JSON to
a socket can be another. This is the reference: how to connect, every method, the data it
returns and the events it pushes.

## Quick start

`scripts/machman-smoke.py` is a stdlib-only Python client. `call` sends any method with its
params as a JSON object and prints the result:

```sh
export MACHMAN_SUITE_ID=com.gustaffranzen.Machman.dev   # a Debug build; unset for Release
scripts/machman-smoke.py                                 # hello, then the VM list
scripts/machman-smoke.py call host.capabilities
scripts/machman-smoke.py call vm.get '{"name": "Debian"}'
scripts/machman-smoke.py call vm.start '{"name": "Debian", "options": {"openWindow": false}}'
scripts/machman-smoke.py watch                           # stream events until ^C
```

```
$ scripts/machman-smoke.py call vm.get '{"name": "nope"}'
vm.get: No VM named “nope” (notFound)
```

A refusal prints its message and Machman's error code and exits 1. Without the script, one
request is one line:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"vm.list"}' \
	| nc -U "$TMPDIR$MACHMAN_SUITE_ID/machman.sock"
```

## Connecting

```
$TMPDIR/<suite>/machman.sock
```

`<suite>` is `$MACHMAN_SUITE_ID`, else the process's bundle id with any `.agent`, `.vmhost` or
`.tests` suffix stripped: `com.gustaffranzen.Machman` for a Release build,
`com.gustaffranzen.Machman.dev` for a Debug build. The two never share a socket or a VM
library.

Sockets live in the runtime dir, not in the VM library: `sun_path` holds 104 bytes, and the
library can move to a volume that cannot host a socket at all. The library is the `VMs` folder
of the data dir, `~/Library/Application Support/<suite>` by default. The `MachmanDataDir`
default moves the data dir; MachmanAgent reads it from its own domain (`<suite>.agent`, e.g.
`defaults write com.gustaffranzen.Machman.agent MachmanDataDir /Volumes/Big/Machman`) and hands
it to every vmhost it spawns.

The socket is mode 0600: file permissions are the auth boundary (the same user only). One
daemon serves a socket: a second instance finds the live listener and refuses to start, and a
stale socket file is reclaimed. A listener touches its socket hourly, so the system's temp-dir
cleaner (which removes entries untouched for 3 days) never takes a live one.

## Messages

Newline-delimited JSON-RPC 2.0: one JSON object per line, UTF-8, no raw newline inside a
message.

```
--> {"jsonrpc":"2.0","id":1,"method":"machman.hello","params":{"client":"my-tui"}}
<-- {"id":1,"jsonrpc":"2.0","result":{"apiVersion":1,"daemonVersion":"1.0.14"}}
```

- **Hello first.** Send `machman.hello` and check `apiVersion` (currently `1`).
- **Ids.** A request carries an `id` (number or string). A line without one is a notification
  and is never answered, not even with method-not-found. The daemon's own event notifications
  carry no id.
- **Results.** A call with nothing to return answers `{}`; one whose answer is "none" (no
  preview) answers `null`.
- **Concurrency.** Requests on one connection run concurrently and are answered as they finish,
  matched by id, so replies can arrive out of order and two requests in flight may take effect
  in either order (a `vm.disk.add` and a `vm.start` sent back to back can boot without the
  disk). A client that needs an order waits for one reply before sending the next request. An
  event a request causes can arrive before or after its reply.
- **Deadlines are the client's.** Nothing on the wire carries one: bound your wait and abandon
  the id when it expires (the Swift client waits 30 s, longer for boot- and copy-class calls).
  A reply to an id nobody awaits is dropped, so a late one is never misdelivered. An expired
  deadline says nothing about the server — the call may still complete (watch events) — and is
  no reason to drop the connection. A dropped connection says as little about the calls in
  flight: re-read state after reconnecting.
- **Keep reading.** A client that leaves the daemon's writes blocked for 10 s, or lets 32 MiB
  queue up (an event subscription it stopped draining), is disconnected.

## Errors

```
<-- {"error":{"code":-32000,"data":{"machmanCode":"notFound"},"message":"No VM named “x”"},"id":2,"jsonrpc":"2.0"}
```

The standard JSON-RPC codes mean what they always do: -32700 parse error, -32600 invalid
request, -32601 method not found, -32602 invalid params. Everything Machman refuses is -32000
with `data.machmanCode`:

| `machmanCode` | Meaning |
|---|---|
| `notFound` | No such VM, disk, mount, file, script or operation. |
| `alreadyExists` | The name or the file is taken. |
| `invalidState` | Not now: the VM runs, starts, installs, is held by a copy or an import, or a newer Machman wrote part of it. The message says which. |
| `macConflict` | `vm.start`: a running or starting VM uses this VM's MAC. `force` overrides. |
| `invalidArgument` | A value breaks a rule (a name, a size, a value from a closed set); the message says which. |
| `ioFailure` | A file operation failed. |
| `virtualizationFailure` | Virtualization.framework refused or failed. |
| `installFailure` | A macOS install failed. |
| `internalError` | Anything else. Read a code you don't know as this one. |
| `timeout` | The daemon's own bounded call to a vmhost got no reply; the vmhost is left alone, and the message names the deadline ("No answer within 30 seconds"). |
| `cancelled` | The user cancelled what the call was doing (a stop or `op.cancel` during a start). A never-mind, not a failure. |

-32601 from Machman means an older daemon or vmhost without that method: fall back or say
what to update (the Swift client reads it as `unsupported`; it is never sent as a
`machmanCode`). Messages are one sentence for people to read; match on the code, never on the
text, which a newer daemon may reword.

## Conventions

### Names

Every method that takes a new name checks it where it enters: `invalidArgument` with a
one-sentence reason, `alreadyExists` for a taken name. Names stored before a rule existed keep
working; nothing is refused at load.

- VM, disk and mount names and kernel tags: not empty, no `/`, no leading `.`, no control
  characters (tab, line break …), at most 255 UTF-8 bytes (disk names 251: the file adds
  `.raw`).
- VM names also exclude `${` (ssh expands `${VAR}` in the key and pin paths that carry the
  name, with no escape).
- Mount tags also exclude `: \ * ? | < >` (Virtualization's shared-folder rule) and the
  reserved Guest Setup share names (`alreadyExists`; see `guestSetup` under DeviceInfo).
- Disk names and tags are trimmed. VM names with leading or trailing spaces are refused
  (clients trim): the daemon keys on the name as sent.

### Values to tolerate

- **Open string sets.** `state`, `disks[].type`, `boot.mode`, `macInstallState.kind`,
  `ownedKernels[].role`, serial-port `kind`, device `kind`, `reverseState`, `reachability`,
  operation `kind` and `state`, event `type`, and every other closed-looking set may grow:
  render a value you don't know as "unknown", never fail the payload. In requests the daemon
  refuses values it doesn't know with `invalidArgument` (`vm.stop`'s `mode` is strict: -32602).
- **Optional fields.** New optional fields may appear at any time; a field this document lists
  as optional (`?`) may be absent. `enabled` on disks, mounts, serial ports and devices: absent
  means enabled.
- **Dates** are ISO 8601 strings.
- **Paths are the server's.** `disks[].path`, `ssh.identityFilePath` and the other paths a VM
  lists are resolved by the daemon; never derive a library path or a naming policy yourself.

### The start policy is the client's

`vm.start` takes explicit options only, so a client that sends a plain start without reading
the VM's `startPolicy` starts every VM windowed and unsafe. Machman's own clients send:

| Start | `options` |
|---|---|
| Start | `{openWindow: startPolicy.windowed, safe: startPolicy.safe}` (no `startPolicy`: windowed, not safe) |
| Start Headless | `{openWindow: false, safe: startPolicy.safe}` |
| Start Safe | `{openWindow: startPolicy.windowed, safe: true}` |

(MachmanUI's `StartIntent`; `scripts/machman-smoke.py start` does the same.)

## Methods

Per-VM calls take the VM's `name`. While a VM runs, its calls go to its own vmhost (see
Per-VM host processes); the socket stays the single entry point.

### Hello, host and operations

| Method | Params | Result |
|---|---|---|
| `machman.hello` | `{client}` | `{apiVersion, daemonVersion, host?}` |
| `host.capabilities` | — | `HostCapabilities` |
| `host.operations` | — | `[OperationInfo]` |
| `op.cancel` | `{id}` | `{}` |
| `host.installRosetta` | — | `{}` |
| `host.setupScripts.import` | `{path, vm?}` | `GuestSetupScriptInfo` |
| `events.subscribe` | — | `{}` |
| `daemon.retire` | — | `{}` |

- **`machman.hello`**: `host` comes only from a vmhost (see Per-VM host processes).
- **`host.operations`**: the long-running operations now live, for a client resyncing after a
  reconnect (events have no replay). Finished ones stay listed for about 10 s.
- **`op.cancel`**: `notFound` when the operation finished or is unknown; `invalidState` when it
  can't be cancelled, or when no vmhost had it but one didn't answer within 3 s and it may run
  there ("… is not responding — try again in a moment"). The daemon asks every vmhost at once.
- **`host.installRosetta`**: installs Rosetta for Linux guests through macOS's own prompt,
  reported as an operation. On macOS 27 it is a no-op success.
- **`host.setupScripts.import`**: copies a script file on this Mac — a regular UTF-8 text file
  of at most 1 MB — into the Guest Setup script store as a `custom` script, labeled with its
  file name and dated with `vm`, the VM it is for. The same bytes again answer with their first
  entry. `invalidArgument` "“…” isn’t a file", "“…” is larger than 1 MB" or "“…” isn’t a text
  file"; a `listChanged` follows. The store sits beside the library
  (`<data dir>/GuestSetup/scripts/<id>/`), outside every VM, and Machman never deletes an entry.
- **`events.subscribe`**: events then arrive on this connection; the subscription is in place
  before the reply.
- **`daemon.retire`**: the daemon stops serving and exits, leaving vmhosts and their VMs
  running for a successor to re-adopt. `invalidState` while the daemon itself runs work that
  would die with it — a start, a copy, an import or promote into a stopped VM, a macOS install —
  naming it ("… is installing macOS — try again when it finishes"). A vmhost refuses it.

### The library

| Method | Params | Result |
|---|---|---|
| `vm.list` | — | `[VMInfo]` |
| `vm.get` | `{name}` | `VMInfo` |
| `vm.create` | `{template?}` | `VMInfo` |
| `vm.delete` | `{name}` | `{}` |
| `vm.rename` | `{name, newName}` | `{}` |
| `vm.copy` | `{name, newName?, diskIDs?, mountIDs?, regenerateMAC?}` | `VMInfo` |

- **`vm.list`, `vm.get`**: never wait longer than 3 s for a vmhost (see `unresponsive`). A VM
  folder whose config can't be read is left out of the list, with a warning (see Events).
- **`vm.create`**: named `new-VM<n>`. `template` `"blank"` has no devices, `"default"` (or
  none) the implied EFI device set and no disk, `"mac"` the macOS-guest set minus the trackpad.
  An unknown template answers `invalidArgument`; one that isn't a string, -32602.
- **`vm.delete`**: refused while the VM runs or installs, or while another VM uses a file in
  its folder. A guest→Mac key that can't be removed from `~/.ssh/authorized_keys` is reported
  as a warning `log` event.
- **`vm.rename`**: refused like `vm.delete`, and when a vmhost still answers on the new name's
  socket. `newName` follows the name rules.
- **`vm.copy`**: refused while the VM runs. `newName` follows the name rules; `diskIDs` are the
  writable disks to carry and `mountIDs` the mounts (by `MountInfo.id`), all of them when
  absent; `regenerateMAC` defaults to true. The copy is a new machine: a fresh machine
  identity, autostart off, no serial logs and no ssh keypair, and it serves Guest Setup at its
  first boot like a new guest. A Mac whose install never finished copies as `failed`
  "Duplicated before macOS was installed". Progress comes as `operationChanged`, and as
  `copyProgress` with vm = the copy.

### Settings

| Method | Params | Result |
|---|---|---|
| `vm.setHardware` | `{name, cpuCount?, memoryBytes?, nestedVirtualization?}` | `{}` |
| `vm.regenerateMAC` | `{name}` | `VMInfo` |
| `vm.setStartPolicy` | `{name, policy: {windowed, safe, autostart}}` | `{}` |
| `vm.setSafety` | `{name, disks?: {id: bool}, mounts?: {id: bool}}` | `{}` |
| `vm.setEnabled` | `{name, disks?: {id: bool}, mounts?: {id: bool}, console?: {"<index>": bool}, uart?: {"<index>": bool}, devices?: {"<kind>": bool}}` | `{}` |

- **`vm.setHardware`**: clamped to the host's limits and the boot mode's floors. Nested
  virtualization applies to EFI and kernel boots on hardware that supports it, and is skipped
  with a warning event otherwise.
- **`vm.regenerateMAC`**: a new random MAC, saved. Refused while the VM runs.
- **`vm.setStartPolicy`**: `autostart` with `safe` is `invalidArgument`. Turning `autostart`
  on or off installs or removes the VM's launchd job. `invalidState` while a safe run is hosted;
  turning autostart on is also refused while another VM that starts at login shares one of this
  VM's writable disk files or its MAC (as their configs on disk say).
- **`vm.setSafety`**: the safe-run policy per disk and mount. An unknown id is `notFound` and
  nothing applies. During a safe run it edits the discardable shadow's config.
- **`vm.setEnabled`**: switches parts off and on without removing them; a disabled part stays
  configured and isn't attached at the next start. An unknown id, index or kind refuses the
  whole batch. Disabling a serial port renumbers the guest names of the ports after it, as
  removing it would. Devices take effect at the next boot.

### Running

| Method | Params | Result |
|---|---|---|
| `vm.start` | `{name, options?: {openWindow, force, safe}}` | `{}` |
| `vm.stop` | `{name, mode: "soft"\|"force"}` | `{}` |
| `vm.process.end` | `{name}` | `{}` |
| `vm.safeSave` | `{name, newName}` | `VMInfo` |
| `vm.window.open` | `{name}` | `{}` |
| `vm.window.close` | `{name}` | `{}` |
| `vm.preview` | `{name, maxWidth?}` | `{jpegBase64}` or `null` |

- **`vm.start`**: `options` default to `openWindow: true`, `force: false`, `safe: false`; apply
  the start policy first (see Conventions). Refusals, in the order they are checked:
  - `invalidState` when a newer Machman set the VM's boot mode (`boot.mode` `"unknown"`) or
    added one of its enabled disks (`type` `"unknown"`).
  - `invalidState` when a running or starting VM has one of this VM's writable disk files
    attached (a disk switched off on a running VM stays attached until it stops). `force` does
    not override it.
  - `macConflict` when a running VM, or one still starting, uses this VM's MAC — the earlier
    start wins. `force: true` overrides it.

  `safe: true` runs a discardable shadow (see Safe runs). How a start meets a vmhost still
  around from an earlier one, and the events a start sends, are under Per-VM host processes.
- **`vm.stop`**: `soft` asks the guest to shut down and answers `invalidState` at once while the
  VM lists `unresponsive`; `force` ends the VM. A vmhost that doesn't answer a `force` stop
  within 15 s lists `unresponsive`, and the stop answers `timeout` ("… isn’t answering, so it
  didn’t stop"): a stop never ends a vmhost process. The exception is a `force` stop during a
  start whose vmhost already runs: it ends that vmhost, and the start answers `cancelled` ("The
  start was canceled"). A VM still preparing a safe run is cancelled instead (see Safe runs).
- **`vm.process.end`**: ends the VM's vmhost process, so the VM stops at once. Send it only after
  the user confirmed it, for a VM listed `unresponsive` or whose `force` stop answered
  `timeout`. `invalidState` while its vmhost answers ("… is answering again — use Force Stop"),
  while the VM is stopped, or when no vmhost process can be found. During a start it ends the
  start's vmhost, answering or not, and the start answers `cancelled`. A warning `log` event
  follows.
- **`vm.safeSave`**: turns a running safe run into a real VM without interrupting the guest
  (see Safe runs): the original lists stopped, and the new VM runs unsafe, with a fresh MAC and
  machine identity from its next boot. The disks the run wrote directly (the original's unsafe
  storage disks, whatever their flags say now) move into the new VM's folder, and the original
  keeps them as references. Refused unless the VM runs safe, and when `newName` is taken or
  breaks the name rules; `invalidState` when the library sits on another volume than its safe
  runs. Like `vm.copy`, the saved VM forgets its last Guest Setup run and serves the installer
  at its next boot, which mints its SSH keypair anew.
- **`vm.window.open`, `vm.window.close`**: the VM's vmhost shows or hides its window; the VM
  keeps running.
- **`vm.preview`**: the VM's display as a JPEG, at most `maxWidth` pixels wide; `null` when
  there is none (a stopped or starting VM, no display).

### Disks and mounts

| Method | Params | Result |
|---|---|---|
| `vm.disk.add` | `{name, disk: NewDisk}` | `{}` |
| `vm.disk.remove` | `{name, diskID}` | `{}` |
| `vm.disk.import` | `{name, path}` | `VMInfo` |
| `vm.disk.promote` | `{name, diskID}` | `VMInfo` |
| `vm.disk.resize` | `{name, diskID, sizeBytes}` | `VMInfo` |
| `vm.disk.rename` | `{name, diskID, newName}` | `VMInfo` |
| `vm.mount.add` | `{name, path, tag, kind?}` | `{}` |
| `vm.mount.remove` | `{name, mountID}` | `{}` |
| `vm.mount.setTag` | `{name, mountID, tag}` | `VMInfo` |
| `vm.mount.setKind` | `{name, mountID, kind}` | `VMInfo` |

- **`vm.disk.add`**: `NewDisk` is `{type: "storage", name, sizeBytes}` for a new raw file in the
  VM's folder, or `{type: "image"|"iso", path}` for a file attached where it is. A storage name
  follows the name rules and must be new to the VM (an existing disk or file is never
  replaced); `sizeBytes` is a positive multiple of 512. An image or ISO passes
  `vm.disk.import`'s format check first (`invalidArgument`), a missing file is `notFound`, and a
  file the VM already attaches — by any path, through a link, or as its own storage file — is
  `alreadyExists`.
- **`vm.disk.remove`**: owned files (storage files and ISOs inside the VM's folder) are deleted
  with the entry; other files are only disconnected. `invalidState` while the VM runs, or while
  another VM uses the owned file. An `"unknown"` disk loses only its entry.
- **`vm.disk.import`**: copies a file into the VM as an owned disk. The format comes from the
  file's magic bytes: ISO 9660 becomes an `iso`, qcow2 is refused, anything else is raw
  `storage`, which must be a non-empty multiple of 512 bytes. Progress comes as
  `operationChanged` and `copyProgress`.
- **`vm.disk.promote`**: copies a referenced disk into the VM's folder and swaps the entry in
  place, keeping its safe flag and position. `invalidState` for a disk that is owned already, or
  while the VM runs. Progress as for an import.
- **`vm.disk.resize`**: grows an owned storage disk; it never shrinks one. `sizeBytes` is a
  positive multiple of 512. Refused while the VM runs.
- **`vm.disk.rename`**: renames an owned storage disk: its file moves, and its `id`, which
  comes from the name, changes. `newName` follows the name rules. Refused while the VM runs, or
  while another VM uses the file.
- **`vm.mount.add`**: shares a host folder. `tag` follows the mount-tag rules. `kind`
  `"virtiofs"` (the default) rides Virtualization's share device; `"sshfs"` is mounted by the
  guest over its SSH link, and is refused for macOS guests.
- **`vm.mount.setTag`, `vm.mount.setKind`**: take effect at the next boot. A tag must be unique
  on the VM; `sshfs` is refused for macOS guests.

### Boot, kernels and the macOS install

| Method | Params | Result |
|---|---|---|
| `vm.boot.setKernel` | `{name, enabled}` | `{}` |
| `vm.boot.kernelSettings` | `{name, settings: {kernelPath, initrdPath?, commandLine}}` | `{}` |
| `vm.kernel.promote` | `{name, role: "kernel"\|"initramfs", sourcePath, tag}` | `VMInfo` |
| `vm.kernel.delete` | `{name, path}` | `VMInfo` |
| `vm.kernel.rename` | `{name, path, tag}` | `VMInfo` |
| `vm.kernel.setOverride` | `{name, path, commandLine?, overrideEnabled?}` | `VMInfo` |
| `vm.kernel.clear` | `{name}` | `VMInfo` |
| `vm.install.start` | `{name, source: {kind: "latest"} \| {kind: "ipsw", path}, diskID?}` | `{}` |
| `vm.install.cancel` | `{name}` | `{}` |
| `vm.install.phase` | `{name}` | `InstallPhase` |

A VM boots by EFI, by a Linux kernel it is given, or as macOS. The kernel calls edit the
**kernel draft** (`boot.kernel`) and the VM's **owned kernel files** (copies inside its folder).
On a macOS VM, `vm.boot.kernelSettings`, `vm.kernel.promote`, `vm.kernel.rename` and
`vm.kernel.setOverride` answer `invalidState` "… is a macOS VM — its kernel files can only be
removed".

- **`vm.boot.setKernel`**: switches kernel boot on or off. Refused once macOS is installed, and
  `invalidState` when a newer Machman set the boot mode. Switched off, the draft stays while it
  holds a kernel or initramfs path or a command line; a draft that holds nothing goes.
- **`vm.boot.kernelSettings`**: replaces the whole draft. While kernel boot is off, settings
  that hold nothing (no path — an empty `initrdPath` counts as none — and a blank command line)
  drop the draft.
- **`vm.kernel.promote`**: copies a file into `<vm>/kernels/<role>/<tag>/` as an owned file and
  points the role's draft field at it. `tag` follows the name rules; a tag that already holds a
  kernel file of that role answers `alreadyExists` "“<tag>” already holds a kernel file".
- **`vm.kernel.delete`**: removes an owned kernel file — `path` must name one of the VM's owned
  files once `..` is resolved, else `notFound` — and clears every field that references it. A
  draft left holding nothing while kernel boot is off goes.
- **`vm.kernel.rename`**: moves an owned kernel file to another tag; the draft's references and
  the file's command-line override follow it. Refused while the VM runs; the same
  `alreadyExists` rule as promote.
- **`vm.kernel.setOverride`**: a command line for one owned kernel file, used instead of the
  VM's while that file boots and the override is enabled. Absent fields stay as they are; the
  override goes with the file.
- **`vm.kernel.clear`**: removes the draft (`boot.kernel` is absent after), every owned kernel
  file and their overrides in one call; the boot mode stays, so a macOS VM stays macOS.
  `invalidState` while kernel boot is on ("Choose another bootloader for … before removing its
  kernel settings"), while the VM runs or a start, copy or import holds it, and when a newer
  Machman set the boot mode.
- **`vm.install.start`**: installs macOS from the newest restore image this Mac can install
  (`latest`) or from a local `.ipsw`. `invalidState` once macOS is installed, while that VM's
  install runs, or when a newer Machman set its boot mode or added one of its enabled disks; a
  retry after a failed or cancelled install starts over. macOS installs onto the VM's first
  disk: without `diskID` a new 64 GB disk goes first and the VM's other disks follow it, except
  on a retry, which reuses the VM's own first disk when that one is writable. `diskID` names one
  of the VM's disks to install onto instead: it is erased, moved first and enabled. An ISO or a
  disk a newer Machman added answers `invalidArgument`, a file another VM's config names
  `invalidState`, a disk the VM no longer has `notFound`; a small disk is never refused.
  Progress comes as `installPhaseChanged`.
- **`vm.install.phase`**: where the VM's install stands now.

### Devices and serial ports

| Method | Params | Result |
|---|---|---|
| `vm.device.add` | `{name, kind}` | `VMInfo` |
| `vm.device.remove` | `{name, kind}` | `VMInfo` |
| `vm.device.update` | `{name, device: DeviceInfo}` | `VMInfo` |
| `vm.console.add` | `{name}` | `{}` |
| `vm.console.remove` | `{name}` | `{}` |
| `vm.uart.add` | `{name}` | `{}` |
| `vm.uart.remove` | `{name}` | `{}` |
| `vm.serial.setLogging` | `{name, kind: "console"\|"uart", index, config: SerialLogConfig}` | `{}` |

- **`vm.device.add`**: one device per kind; which kinds fit depends on the boot mode (the
  trackpad needs macOS; clipboard and rosetta refuse it). Takes effect at the next boot.
- **`vm.device.remove`**: removing `guestSetup` from a running VM leaves its served share in
  place until the VM stops.
- **`vm.device.update`**: replaces the whole device. Every setting comes from the request and
  an absent one is cleared (absent `systemKeyCapture` = off), so send back the `DeviceInfo` you
  read with only your change applied. `unavailable` is ignored on input.
- **`vm.console.add`, `vm.uart.add`**: append a virtio console port (guest `/dev/hvcN`) or a
  PL011 uart port (guest `/dev/ttyAMAN`; see `SerialPortInfo.unavailable`). The `remove` calls
  drop the last port of that kind. All four are refused while the VM runs.
- **`vm.serial.setLogging`**: retunes a port's log file. While the VM runs it applies at once,
  appending to this boot's log (only a run's first open empties a `resetOnBoot` file).
  `maxBytes` above 1073741824 (1 GiB) is `invalidArgument`, unless it is the port's stored cap
  sent back unchanged.

### SSH and Guest Setup

| Method | Params | Result |
|---|---|---|
| `vm.ssh.set` | `{name, integrationEnabled?, reverseApproved?, alias?}` | `VMInfo` |
| `vm.ssh.refresh` | `{name}` | `{}` |
| `vm.ssh.reset` | `{name}` | `VMInfo` |
| `vm.setup.reset` | `{name}` | `VMInfo` |
| `vm.setup.serve` | `{name, serve}` | `VMInfo` |
| `vm.setup.pin` | `{name, id}` | `VMInfo` |

Machman gives each VM an `~/.ssh` entry (`ssh <alias>`) and can let the guest reach the Mac
over SSH (reverse access, which sshfs mounts use). Guest Setup is the installer a guest runs
from its share to set all of that up; its report comes back as `VMInfo.setup`.

- **`vm.ssh.set`**: absent fields stay as they are.
  - `integrationEnabled` switches the VM's `~/.ssh` entry on or off.
  - `alias` renames the entry; an empty alias resets it to the default (see `SSHInfo.alias`).
    It must be a valid ssh_config Host name, and is refused when another VM already answers to
    it in any letter case (ssh keys the host-key pin by the lowercased alias), as that VM's
    config on disk says.
  - `reverseApproved: true` needs a reported reverse key and installs its line in
    `~/.ssh/authorized_keys` first; a line the Mac refuses refuses the approval, with nothing
    recorded. `false` denies it: the key stays on file, nothing is installed, and the state
    returns to `pending` only when the guest reports a different key.

  A deny, revoke or `vm.ssh.reset` whose line can't be removed is reported as a warning `log`
  event naming it. Refused during safe runs: the Mac's `~/.ssh` must not follow a discardable
  run.
- **`vm.ssh.refresh`**: looks for the guest's address again now. The daemon's own; a vmhost
  refuses it.
- **`vm.ssh.reset`**: forgets all SSH state — settings, the per-VM keypair, payload and report
  folders, and what it put in `~/.ssh`. Refused during safe runs.
- **`vm.setup.reset`**: forgets the Guest Setup report (`setup` and the report drop-box). The
  guest keeps what the script installed; SSH state has its own reset.
- **`vm.setup.serve`**: sets `setup.reinstallRequested`: an installed guest is served the
  installer only while it is set. On fills the share at once for a running VM; off waits for
  the run to end (the share is emptied at teardown, never mid-run), and a start with serving off
  attaches the two reserved folders empty. A guest that never installed is always served.
- **`vm.setup.pin`**: pins the VM to the stored Guest Setup script `id` (from `setup.scripts`):
  it serves those bytes from its next served start — at once while it runs and serves, a guest
  run in progress keeping the file it opened — whatever build of Machman writes the payload. An
  app update never moves a pin; a VM with none is pinned to the script its first served start
  served. `invalidState` "Guest Setup isn’t attached to …", `notFound` "That Guest Setup script
  isn’t in Machman’s store".

## Data types

### VMInfo

| Field | Type | Notes |
|---|---|---|
| `name` | string | The VM's name, the key of every per-VM call. |
| `state` | string | `stopped`, `starting`, `running`, `stopping`, `paused`, `error`, or `unknown` (a vmhost not adopted yet, or one that never answered). |
| `created`, `lastRan?` | date | |
| `totalRuntimeSeconds?` | number | |
| `cpuCount`, `memoryBytes` | number | |
| `macAddress?` | string | |
| `nestedVirtualization?` | bool | |
| `windowOpen` | bool | The vmhost shows the VM's window. |
| `startPolicy?` | StartPolicy | `{windowed, safe, autostart}`; applied by the client (see Conventions). |
| `boot` | BootInfo | |
| `disks` | [DiskInfo] | In attach order. |
| `mounts` | [MountInfo] | |
| `devices?` | [DeviceInfo] | |
| `consolePorts?`, `uartPorts?` | [SerialPortInfo] | |
| `ssh?` | SSHInfo | Absent when SSH was never used. |
| `setup?` | GuestSetupInfo | Absent when Guest Setup was never used. |
| `safeRun?` | bool | Overlay: true while a safe run stands in for the VM. |
| `unresponsive?` | bool | Overlay: true while the VM's vmhost misses its 3 s answer deadline. |
| `outdatedHost?` | bool | Overlay: true while the VM runs under a vmhost older than the daemon. |

The overlays come from the daemon, not the VM's config, and are absent when false:

- **`unresponsive`**: the rest of the entry is the vmhost's last answer (`state` `unknown` if
  it never answered), and a `listChanged` follows when it answers again. `vm.list`, `vm.get`
  and `host.operations` never wait longer than that deadline per vmhost (a stalled vmhost's
  operations are left out until it answers).
- **`outdatedHost`**: a vmhost that outlived an update of the app. Its setting changes answer
  `invalidState` ("Restart … to finish updating") until it restarts; stop, its window, preview
  and `vm.safeSave` keep working.

### DiskInfo

| Field | Type | Notes |
|---|---|---|
| `id` | string | The disk's `diskID`. A storage disk's comes from its name. |
| `type` | string | `storage` (a raw file in the VM's folder), `image` (a disk image attached where it is), `iso` (a read-only installer, attached as USB storage), `unknown` (a newer Machman's disk). |
| `name?` | string | Storage disks. |
| `path?` | string | The file; for storage, resolved by the daemon. |
| `sizeBytes?` | number | |
| `safe` | bool | Safe-run policy: true runs a discardable clone, false attaches the real file. |
| `owned?` | bool | The file lives inside the VM's folder and travels with it. |
| `enabled?` | bool | Absent = enabled; a disabled disk isn't attached at the next start. |

An `unknown` disk has no path or size, is saved back as written, loses only its entry in
`vm.disk.remove`, and refuses a start while it is enabled.

`NewDisk` (for `vm.disk.add`): `{type, name?, path?, sizeBytes?}`, see that method.

### MountInfo

| Field | Type | Notes |
|---|---|---|
| `id` | string | The mount's `mountID`. |
| `path` | string | The host folder. |
| `tag` | string | The name the guest mounts it by. |
| `safe` | bool | Safe-run policy: true leaves the mount out of a safe run. |
| `enabled?` | bool | Absent = enabled. |
| `kind?` | string | `virtiofs` (absent) or `sshfs`. |
| `automounted?` | bool | The guest's report says it mounts at boot (Guest Setup's one share automount covers every virtiofs mount; sshfs mounts match by tag). |
| `automountedAt?` | string | The guest folder it lands at. |

### BootInfo

| Field | Type | Notes |
|---|---|---|
| `mode` | string | `efi`, `linuxKernel`, `macOS`, or `unknown`: a mode a newer Machman wrote, kept as written and never booted. |
| `kernel?` | `{kernelPath, initrdPath?, commandLine}` | The kernel draft. |
| `macInstallState?` | `{kind, message?}` | macOS mode: `installing`, `installed`, `failed` (with `message`), `interrupted`. |
| `minCPUCount?`, `minMemoryBytes?` | number | The boot mode's floors. |
| `ownedKernels?` | `[{role, tag, fileName, path, overrideCommandLine?, overrideEnabled?}]` | The VM's kernel files, `role` `kernel` or `initramfs`; listed in every mode (a macOS VM keeps its kernel files until removed). |

### DeviceInfo

`{kind, enabled, displayWidthPixels?, displayHeightPixels?, displayPixelsPerInch?,
systemKeyCapture?, sharesClipboard?, unavailable?}`, one per kind:

| `kind` | Device |
|---|---|
| `keyboard`, `pointer`, `trackpad` | Input (the trackpad needs a macOS guest). |
| `graphics` | The display: `displayWidthPixels`, `displayHeightPixels`, `displayPixelsPerInch` (macOS guests), `systemKeyCapture`. |
| `audioInput`, `audioOutput` | Sound, with the Mac's default microphone and output. |
| `network` | NAT networking; the MAC is `VMInfo.macAddress`. |
| `clipboard` | Clipboard sharing through a spice agent port (`sharesClipboard`); not for macOS guests. |
| `entropy` | A virtio random-number device. |
| `rosetta` | Rosetta for Linux guests, shared as tag `rosetta`; not for macOS guests. |
| `guestSetup` | Guest Setup, the installer (below). |
| `consoleLoginInstaller`, `sshInstaller` | Old installer kinds: collapsed into `guestSetup` when a config loads, and mapped onto it by `vm.device.add` and `vm.device.remove`. |

Send a kind you don't recognize back unchanged. With no `devices`, a VM has the implied set:
keyboard, trackpad, pointer, graphics, audioInput, audioOutput and network for a macOS guest;
keyboard, pointer, graphics, audioInput, audioOutput, network and clipboard otherwise.

**`unavailable`** `{reason, message, sinceOSVersion?}`: the device can't be used here.
`reason` is `privateUARTGated`, `classUnavailable`, `notInstalled` (Rosetta, installable with
`host.installRosetta`) or `unsupportedHost`; `message` is ready to show.

**`systemKeyCapture`** (graphics): `off`, `always` or `fullScreen` (absent = off), the mode a
run starts with for sending system shortcuts (⌘Space, ⌘Tab …) to the guest. The run's own value
lives in the VM's window (its menu and ⌃⌥⌘K) and is not on the wire. Send a value you don't
recognize back verbatim: the daemon keeps a stored mode it doesn't know and serves it as stored.

**`guestSetup`** works in every boot mode. It is a read-only `GuestSetup` share carrying one
generated script that sets up everything guest-side — console logins, kernel console output,
SSH, guest→Mac SSH, sshfs and boot automounts — plus a writable `GuestReport` drop-box the guest
reports through. The guest mounts the share at `/mnt/machman/share` (virtiofs, or sshfs of
`ssh.setupSharePath` where there is no virtiofs driver; the same path either way); sshfs-kind
host folders land under `/mnt/machman/mounts`. The script keeps its state at
`/var/lib/machman/state.env` (Linux) or `/var/db/machman/state.env` (BSDs, macOS), beside a
copy of itself that refreshes the report at every boot without reading the share. `GuestSetup`,
`GuestReport` and the old `LoginInstaller`, `SSHSetup` and `SSHReport` are reserved mount
tags. The share's content exists only while the VM runs: written at start (or when the
installer is attached to a running VM), removed at stop after the last report is read, and
swept when the daemon starts.

### SerialPortInfo

| Field | Type | Notes |
|---|---|---|
| `kind` | string | `console` (virtio) or `uart` (PL011). |
| `index` | number | The port's position in the VM's config. |
| `guestIndex?` | number | The number in `guestDevice`: enabled ports numbered without gaps, as the guest sees them at the next boot. Absent: use `index`. |
| `guestDevice` | string | The device the guest should see (`hvc0`, `ttyAMA0`, `cu.virtio0`), from the boot mode. |
| `guestName?` | string | The device name the guest itself reported (`ttyV0.0`, `hvc0`). Prefer it when present. |
| `enabled?` | bool | Absent = enabled. |
| `logging` | SerialLogConfig | `{mode, maxBytes?}`: `mode` `disabled`, `resetOnBoot` (default) or `continuous`; `maxBytes` 0 or absent = unlimited, at most 1073741824. A mode a daemon doesn't know is kept as written and logs like `resetOnBoot`. |
| `socketPath?` | string | The port's data socket while the VM runs (see Not on this socket). |
| `logPath?` | string | The log file, when logging is on. |
| `mmioBase?`, `irq?` | string, number | uart ports, once the platform info is generated. |
| `unavailable?` | `{reason, message, sinceOSVersion?}` | The port can't attach on this Mac and is left off the running VM. Today only uart ports: from macOS 26.6.1 (`sinceOSVersion`), Virtualization keeps the PL011 to Apple's own apps (`reason` `privateUARTGated`). |

### SSHInfo

Absent when SSH was never used. A running VM has a discovered address whether or not anyone
asked for SSH, so a present `ssh` alone does not mean SSH is set up there: `configured` says
that.

| Field | Notes |
|---|---|
| `configured?` | SSH is part of this VM: state on file, or the installer attached. |
| `integrationEnabled?` | The VM's `~/.ssh` entry is on. |
| `alias?` | The effective `~/.ssh` name: the VM's own if set, else the VM name mapped into the alias charset plus `.machman` (`dev copy` → `dev-copy.machman`). When that default is another VM's already, the VM taking the name stores a numbered one (`dev-copy-2.machman`), which no other VM's change moves. |
| `reverseState` | `none`, `pending`, `approved` or `denied`: guest→Mac access. |
| `reversePublicKey?` | The guest's reverse key (public half). |
| `guestUser?`, `guestHostname?`, `guestOS?`, `guestOSVersion?`, `guestHostKey?` | From the guest's report. |
| `lastReportAt?`, `lastRunStatus?`, `lastRunNote?`, `lastTransport?`, `scriptVersion?` | The last Guest Setup run, as for `setup`. |
| `sshfsAvailable?`, `sshfsMountReady?`, `sshfsMountRoot?` | Whether the guest can mount host folders over SSH — usable only once `reverseState` is `approved`; compute that, don't cache it. |
| `identityFilePath?`, `knownHostsPath?` | The per-VM key and host-key pin, once the key exists. |
| `setupSharePath?` | The folder a guest without a virtiofs driver sshfs-mounts to reach its share: the rename-stable link `<library>/.machman-shares/<marker>` once a start has pointed it, the VM's own share before that. The script's boot-time sshfs mount of the share goes through the same link. |
| `hostUser?` | The Mac account Machman runs as. |
| `address?`, `addressSource?` | Overlay while the VM runs: the guest's address, found by `dhcp`, `arp` or `report`. |
| `hostAddressForGuest?` | Overlay: this Mac's address on the interface whose subnet holds the guest's, absent when none does (never a guessed `.1`). |
| `reachability?`, `reachabilityDetail?`, `readySince?` | Overlay: whether the guest's sshd answers this run — `unknown`, `waiting`, `ready` or `unreachable` (no answer on port 22, or after two minutes no address for the VM's MAC; the detail says which). Never saved. |

### GuestSetupInfo

`VMInfo.setup`: the last Guest Setup report. Absent when the installer was never used.

| Field | Notes |
|---|---|
| `installed?` | The guest finished a run. |
| `guestOS?`, `guestOSFamily?`, `guestOSVersion?`, `guestInit?` | From the guest. |
| `lastReportAt?` | When the Mac read the report. |
| `lastRunStatus?`, `lastRunNote?` | `ok`, `partial` or `failed`, and why a run fell short. |
| `lastTransport?` | How the guest reached its share: `virtiofs`, `sshfs` or `local`. |
| `scriptVersion?`, `currentScriptVersion?` | The script version that reported, and the one this app ships; greater current means a re-run updates the guest. |
| `errors?`, `notes?` | `[{step, message}]`: failures, and informational lines (a repair made, a boot-time refresh that won't run). |
| `features?` | `[{id, available, reason?, configured, detail?}]`, `id` one of `console`, `kernelConsole`, `ssh`, `reverseSSH`, `sshfs`, `virtiofsAutomount`, `sshfsAutomount` (show an unknown one verbatim). |
| `consoles?` | `[{device, login, kernelConsole?}]`, `login` `active`, `active-auto`, `configured`, `none` or `missing`. |
| `automounts?` | `[{kind, target, path}]`, `kind` a mount kind. |
| `reinstallRequested?` | Mirrors `vm.setup.serve`. |
| `scripts?` | While Guest Setup is attached: the store of scripts a VM can serve, `[GuestSetupScriptInfo]`. |
| `servedScript?` | The script id this VM serves: its pin, else this build's. |
| `installedScript?` | The script id the last report's checksum names, when the store holds it. |

`GuestSetupScriptInfo` is `{id, kind, version?, label?, vm?, addedAt?, latest?}`: `kind`
`build` (a Machman build's own, `id` `v<N>-<digest>`; `latest` marks the newest build's),
`custom` (imported with `host.setupScripts.import`, `label` its file name) or `changed` (a copy
a guest changed and ran, kept at most once per VM per served start); `vm` is the VM it was
imported for or captured from. Read an unknown `kind` as `custom`.

### Other types

- **`HostCapabilities`**: `{maxCPUCount, minMemoryBytes, maxMemoryBytes, freeDiskBytes,
  uartUnavailable?, nestedVirtualizationSupported?, rosettaAvailability?,
  hostDisplayWidthPixels?, hostDisplayHeightPixels?, maxSerialPorts?}`. `freeDiskBytes` is free
  space on the volume holding the data dir; `uartUnavailable` is the `unavailable` every uart
  port gets on this Mac; `rosettaAvailability` is `installed`, `notInstalled` or
  `notSupported`.
- **`InstallPhase`**: `{kind, version?, build?, message?, progress?: {fraction,
  completedBytes?, totalBytes?}, downloadStartedAt?}`, `kind` `idle`, `resolving`,
  `downloading`, `installing`, `installed`, `failed` (with `message`) or `interrupted`.
- **`OperationInfo`**: `{id, kind, vm?, label, fraction?, completedBytes?, totalBytes?,
  startedAt, state, message?, cancellable?}`. `kind` is one of `copyVM`, `importDisk`,
  `promoteDisk`, `shadowBuild`, `safeSave`, `kernelImport`, `rosettaInstall` (open set);
  `state` is `running`, `succeeded`, `failed` or `cancelled`; `label` is the phase in words;
  `fraction` absent means indeterminate; `cancellable` false means `op.cancel` would refuse
  (absent = cancellable). An ETA is the client's arithmetic.

## Events

After `events.subscribe` the daemon pushes notifications on that connection:

```
<-- {"jsonrpc":"2.0","method":"event","params":{"state":"running","type":"stateChanged","vm":"Debian"}}
```

| `params.type` | Fields | When |
|---|---|---|
| `stateChanged` | `vm, state` | A VM's state moved. |
| `listChanged` | — | Something in the library changed: re-fetch `vm.list`. |
| `installPhaseChanged` | `vm, phase: InstallPhase` | A macOS install moved. |
| `log` | `vm?, level, message` | Something to tell the user; `level` `message`, `warning` or `error`. |
| `operationChanged` | `op: OperationInfo` | A long-running operation started, progressed or ended. A terminal state comes once; resync with `host.operations`. |
| `copyProgress` | `vm, copiedBytes, totalBytes` | Progress of `vm.copy` (vm = the copy), imports, promotes and safe-run shadow builds (vm = the VM). The same progress as `operationChanged`, in an older form. |
| `sshChanged` | `vm` | The VM's SSH state moved (a report, an address, a switch): re-fetch the VM. |
| `setupChanged` | `vm` | The VM's Guest Setup state moved (a report, a reset): re-fetch the VM. |

Skip a type you don't know. The daemon passes on each event a vmhost emits as the vmhost sent
it, so types and fields the daemon itself doesn't know reach clients unchanged.

A VM folder whose config can't be read is left out of `vm.list`, and the daemon says so with a
warning `log` (vm = the folder's name): to every subscriber right after it subscribes, while the
config still can't be read, and when a listed VM's config stops reading. Once the folder is
gone, its config reads again or a VM is listed under its name, the warning stops; a folder with
no config is no VM and stays quiet.

## Starting and running

### What a start sends

The VM lists as `starting` while a start is in flight (a vmhost's spawn, a safe run's shadow
build). The daemon sends `stateChanged` `starting` once the start's checks pass, then announces
the run with `stateChanged` `running` followed by `listChanged`; a start that fails after
`starting` sends `stateChanged` `stopped` before its `listChanged`. The vmhost's own `running`
may follow just after; a repeated state changes nothing. A new vmhost's own events from before
its start returns are not passed on. The `log` events a vmhost sends while its VM boots (a
serial port it could not attach, a start without a window) reach subscribers.

While a VM starts, most of its per-VM calls answer `invalidState` saying it is starting, and
`vm.preview` answers `null`. The start's vmhost stays reachable: a `force` `vm.stop` or
`vm.process.end` ends it and the start answers `cancelled`, and one that misses the 3 s answer
deadline while starting lists `unresponsive`.

### Copies and imports hold a VM

While a copy writes into a VM's folder or reads it whole — `vm.disk.import`, `vm.disk.promote`,
`vm.kernel.promote` (whether the daemon or the VM's vmhost does the copy), `vm.copy` of it —
`vm.start` and the whole-VM edits answer `invalidState`: "… is importing a disk — try again when
it finishes", "… is promoting a disk", "… is importing a kernel file", "… is being copied".
Imports and promotes into one VM may run side by side; a `vm.copy` runs alone.

### Safe runs

`vm.start {safe: true}` clones the VM into a hidden shadow and runs the shadow as the VM: safe
disks become discardable clones, unsafe disks are the real files, ISOs are referenced, safe
mounts are left out, and every entry keeps its enabled flag. Name, events, socket and window are
all the real VM's. The only sign on the wire is `VMInfo.safeRun: true` while the run lives. At
stop the shadow is deleted; a clean stop copies the last-ran time and total runtime back.

- A safe start that finds the VM already running unsafe answers `invalidState` ("… is already
  running — stop it to start it safe") and leaves that vmhost serving it.
- Building the shadow is a `shadowBuild` operation. `op.cancel` stops it, and so does `vm.stop`
  in either mode (nothing runs yet); the start then answers `cancelled` ("The safe run was
  canceled").
- During the run, `vm.setSafety` edits the discardable shadow and `vm.setStartPolicy` is
  refused; so are `vm.ssh.set` and `vm.ssh.reset`.
- `vm.safeSave` turns the running shadow into a real VM. The disks the run attached directly
  (switching one off mid-run does not detach it) move into the saved VM's folder as its own; the
  original lists them as references into that folder, so the saved VM can't be deleted or
  renamed, nor those disks removed or renamed, while the original uses them. A save that fails
  is undone; if the saved folder or a moved disk can't go back, the saved VM stays in the
  library with a machine identity of its own, both VMs' configs say where each disk is, and the
  daemon lists it at once. Until the saved VM reboots onto its fresh MAC, starting the original
  needs `force` (`macConflict`).
- Safe runs survive daemon restarts (the daemon re-attaches by matching the shadow's recorded
  vmhost pid against the socket's peer) and end with a reboot of the Mac.

### Per-VM host processes

Every running VM lives in its own MachmanVMHost process, which serves this same protocol on
`$TMPDIR/<suite>/vm-<hash>.sock` (hashed because a VM name may be any length; the hash is of
the VM's current name, so after `vm.safeSave` the run answers on the saved VM's path).
MachmanAgent sends per-VM calls on to it and passes its events on as sent. Clients never need
to know; what they can observe:

- One VM crashing takes neither the others nor the daemon down.
- Vmhosts outlive daemon restarts: a new MachmanAgent re-adopts them. A dropped connection to a
  vmhost that still runs is re-established, the VM listing `unresponsive` meanwhile; only the
  vmhost's exit ends the run (and discards a safe run's shadow).
- A vmhost answers `machman.hello` with its own bundle version plus `-vmhost` (one older than the
  daemon lists `outdatedHost`), and says whom it serves: `host: {pid, vm, dataDir, vmDir?,
  shadow}` — its process, the VM by its current name, its data folder (the library, or a safe
  run's run root), the VM's folder where it is now (it follows a rename or a move; absent once
  deleted; for a safe run, the real VM's folder), and whether it serves a safe run's shadow.

**Adoption.** MachmanAgent adopts a vmhost as a VM only when it serves that VM's folder. At
startup it asks every vmhost socket no VM accounts for whom it serves; one that doesn't answer
in time is placed by the VM folder its process holds open, or asked again every 5 s until it
answers or exits. A vmhost whose VM's folder was renamed while it ran makes the renamed VM list
`unknown` and `unresponsive` until it exits (a start is refused; `vm.process.end` ends it). A
vmhost not adopted yet (busy when the daemon started, or started by a launch agent) is adopted
on its VM's next per-VM call or list; until then the VM lists `unknown`, plus `unresponsive`
once an adoption failed (the first failure sends a `listChanged`; from then on the daemon asks
again every 5 s, not on each list). A vmhost that never accepts (frozen) still counts as running
while it lives and listens on the VM's socket. A vmhost answering on one VM's socket for
another — a run an older vmhost saved as a new VM — is adopted as the VM it serves, and starting
the original answers `invalidState` ("… saved from …, still runs on its socket — stop … before
starting …").

**Whole-VM edits** (rename, copy, delete, MAC, disk files, serial ports, kernel files, macOS
install) refuse while any vmhost answers on the VM's socket, adopted or not. One exiting after
its VM stopped is waited out for up to 3 s first, then "… is still shutting down — try again in
a moment". Any per-VM call that meets a vmhost on its way out (its VM stopped, or its connection
dropped) waits for it the same way, then goes to whatever owns the VM; one whose connection
dropped and that neither comes back nor exits answers "… is not responding — try again in a
moment". A vmhost still draining an import into its stopped VM is not waited for: per-VM calls
go to it, and whole-VM edits refuse at once ("… is importing a disk — try again when it
finishes").

**A start and the vmhosts around it.**

- `vm.start` first adopts every vmhost the daemon hasn't (one whose adoption already failed is
  not asked again), so its MAC and shared-disk checks see their VMs; one that can't be adopted
  counts with its config's MAC and every disk it may have attached. A VM sharing one of the
  starting VM's writable disk files (or, without `force`, its MAC) whose run is over — its
  vmhost exiting after the stop — is waited out for up to 3 s before those checks, then "… is
  still shutting down — try again in a moment".
- A vmhost the daemon already holds for the VM is asked first. A running VM answers
  `invalidState` ("… is already running"). An idle vmhost — spawned for a start that was never
  forwarded because its daemon died in between; it exits on its own after 3 minutes — runs this
  start, MAC check included. A safe start there answers `invalidState` ("… is still prepared
  from an earlier start — start it normally, or wait up to 3 minutes to start it safe"), since
  that vmhost runs the real VM, never a shadow.
- An idle vmhost older than the daemon is ended and the start spawns a current one, so the run
  doesn't start locked by `outdatedHost`; one the daemon has no process to end still runs the
  start, locked. An idle vmhost a safe start spawned serves that run's shadow, so a plain start
  ends it and spawns a fresh one; if it can't be ended the start answers `invalidState` ("… is
  still prepared from an earlier safe start — wait up to 3 minutes, then start it again").
- A vmhost whose VM just stopped is exiting once an operation it runs for that VM (an import, a
  kernel promote) has finished: the start waits up to 3 s for it to go and then starts normally;
  if it is still there, the start answers `invalidState` ("… is still shutting down — try again
  in a moment"). A vmhost that misses its answer deadline answers `invalidState` ("… is not
  responding — try again in a moment"), as does every per-VM call whose vmhost can't be reached
  or adopted.

## Not on this socket

**The VM's display.** `VZVirtualMachineView` cannot leave the process that runs the VM, so the
vmhost presents each VM's window; clients only command it (`vm.window.*`) and poll `vm.preview`
for thumbnails.

**Serial text.** Interactive serial runs on a separate data plane. The VM's vmhost serves each
console and uart port as a raw-byte `AF_UNIX SOCK_STREAM` socket; the control socket only
reports its `socketPath` (in `SerialPortInfo`), and clients connect to it directly (e.g.
`socat -,raw,echo=0 unix-connect:<socketPath>`). The daemon never proxies the byte stream. A
port's `socketPath` belongs to the run: every start gets new paths, and a run saved as a new VM
keeps serving its ports at theirs, so always read it, never derive it. Input for a guest that
is not reading its port waits in order, up to 64 KiB beyond the pipe's own buffer; past that,
new input is dropped (logged once), and the port keeps serving every client.

## Versions

The protocol is `apiVersion` 1, and it only grows: new methods, new optional fields, new values
in open sets. A daemon older than its client answers -32601 for a method it lacks and leaves out
fields it doesn't know (see Values to tolerate).

The VM configs are a different matter: a daemon rewrites a config it saves with the keys it
knows, so an older daemon drops what a newer one stored. Machman Desktop therefore refuses to
work with a daemon older than its own oldest-compatible version and offers to replace it, and
the daemon refuses setting changes on a VM run by an older vmhost (`outdatedHost`). A
third-party client that edits VMs should do the same: check `daemonVersion`, and keep one
version of Machman on a library.
