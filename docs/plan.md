# Plan: layout, copy, run modes, and safe mode

Source backlog: `docs/local/todo.md` (untracked). Item numbers below are that file's line numbers.

## Status

| | |
|---|---|
| **0.1** identity varies by configuration | done |
| **0.2** one app bundle | **next** |
| **0.3** paths derived from identity | done |
| **0.4** move the data by hand | dev done; production pending your cutover |
| **1–5** | not started |

---

## Divergences and findings

Only what the plan didn't already say.

### Where things live now

```
~/Library/Application Support/com.gustaffranzen.Machman[.dev]/VMs/   the VM library
$TMPDIR/com.gustaffranzen.Machman[.dev]/                             machman.sock, vm-<hash>.sock
```

| target | bundle id (Debug adds `.dev`) |
|---|---|
| desktop | `com.gustaffranzen.Machman` |
| agent | `com.gustaffranzen.Machman.agent` |
| tests | `com.gustaffranzen.Machman.tests` |

`~/.machman` is no longer referenced. The worktree's `.machman/` is superseded and can be deleted
(it shares blocks with the new library, so removing it frees nothing).

### Divergences

- **The suite identifier is derived, not declared.** The plan assumed an Info.plist key shared by
  every target. Xcode silently drops custom `INFOPLIST_KEY_*` settings — it honours only a fixed
  allowlist — so the agent resolved to its own bundle id and created a *second* library. Helpers
  now strip a known suffix (`.agent`/`.vmhost`/`.tests`/`.uitests`) from their own id instead.
- **`Machman-desktop` now depends on `Machmand`.** Not in the plan. Without it, running the desktop
  scheme left a stale agent binary in build products, carrying the pre-refactor identity, which
  launched and exited without serving.
- **Per-VM sockets are named by hash**, `vm-<8 hex>.sock`. Measured: a name-based path under the
  new library reaches 110 bytes against a 104-byte `sun_path`.
- **Backup exclusion runs on every scan**, not only at disk creation. Every image that exists
  predates the flag, so a creation-only hook would never have marked one.
- **Crash recovery was added** (not in the plan): atomic config writes, a stale-socket sweep at
  startup, a benign exit when a second daemon loses the socket race, and a report when a VM's
  config can't be read. Verified by `SIGKILL`ing a daemon and a running vmhost together.
- **Phase 0.2 gained the vmhost bundle** — see below. Autostart forced it.

### Problems worth remembering

- **Changing a bundle identifier invalidates every TCC grant.** This cost several rounds and will
  recur at production cutover, when the real `Machman.app` changes identity and loses its Screen
  Recording grant the same way.
- **Screen Recording is granted to the *responsible* process.** A `posix_spawn`ed vmhost inherits
  Machmand's identity, which is why the prompt names Machmand and no `MachmanVMHost` row exists.
  `CGPreflightScreenCaptureAccess()` answers for the *calling* process, so gating capture on it
  vetoes a call that would have succeeded through the parent's grant. Don't reintroduce that gate;
  attempt the capture and report on real failure.
- **`xcodebuild test` launches the app and its daemon**, because the test host is the desktop app.
  A stray `Machmand` after a test run is expected.
- **Kill machman processes by exact name** (`pkill -x Machmand`). A daemon launched as
  `./DerivedData/...` evades `pkill -f` patterns written against an absolute path, and one held the
  socket for hours while appearing dead — invalidating every test run in between.
- **Swift `print` is block-buffered off a tty**, so daemon logs vanish exactly when you need them.
  Diagnostics that matter go to stderr.
- Two copies of the same bundle id exist on disk (worktree `DerivedData` and Xcode's). Launch
  Services registers one; `open <path>` on the other reports "already running".

---

## Phase 0.2 — one app bundle (next)

```
Machman.app/Contents/
  MacOS/MachmanDesktop                    the GUI
  Library/MachmanVMHost.app               per-VM host, its own bundle id <suite>.vmhost
  Library/LoginItems/MachmanAgent.app     the menu-bar daemon, via SMAppService.loginItem
```

Replaces two sibling apps and the `CopyFiles` phase that embeds the vmhost today.
`DaemonConnection.launchDaemon()`'s bundle hunt collapses to an `SMAppService` registration, the
daemon appears in System Settings → Login Items, and the vmhost path becomes stable — which is what
the autostart agents in 4.3 need so their plists don't rot.

**The vmhost becomes a real `.app` with its own identifier**, and is granted Screen Recording
directly. Two independent reasons: per-VM launchd autostart (4.3) means it is *not* a child of
Machmand, so responsible-process inheritance cannot be the foundation; and the window menu (4.5)
wants a bundle anyway. `MachmanPaths.helperSuffixes` already contains `.vmhost`.

**Verify before building on it:** whether a bundled, signed helper is its own TCC client when
`posix_spawn`ed, or still inherits Machmand. If it inherits, the grant needed differs by launch
path — Machmand's when you press Run, the vmhost's when launchd starts it — which would present as
"previews work one way and not the other". If so, disclaim responsibility at spawn
(`posix_spawnattr_setdisclaim`, requiring hand-rolled `posix_spawn` and its own supervision) or
launch via Launch Services with arguments.

---

## Phase 1 — foundations

Nothing user-visible; all of it makes 2–5 small.

**1.1 `MachmanUI` package product** (SwiftUI, depends on MachmanAPI). The symbol vocabulary as
named constants (`.runningWindowed` = `macwindow`, `.runningHeadless` = `terminal`, `.safeMode` =
`shield.lefthalf.filled`, …), answering :37 and unblocking :29 and :35. `VMActionButton` moves here
from `VMNavigationView.swift:11-74` where it is dead code, with its ignored `bSize`/`fSize` fixed.
Plus `CopyToClipboardButton` and the two tooltip idioms. Adding a package product trips the stale
package-resolution quirk in `CLAUDE.md` — do the DerivedData delete and resolve immediately.

**1.2 Collapse `RoutingMachman`'s proxy boilerplate.** ~20 methods repeat
`if let host = hosted[name] { proxy } else { local }`. One `route()` helper, plus a `HostIdentity`
carrying `publicName` / `directoryName` / `socketPath`. **The highest-leverage step in the plan:**
safe mode needs a display-name → shadow-directory translation on every proxied call, and this makes
it one edit instead of twenty. Behaviour unchanged here.

Also **adopt before spawning**: `start` spawns unconditionally when `hosted[name] == nil`, but once
autostart agents can bring a vmhost up on their own, a live socket may exist that this daemon never
adopted. Probe and adopt first, falling back to spawn.

**1.3 One persisted-model pass.** `VMConfig.swift:122-124` documents a four-site lockstep with no
compiler enforcement, so land all fields together — and delete one site first by replacing
`init(name:)`'s hand-copy with a static `load(name:)`.

- Decouple directory from name: a stored `directoryPath` behind `configFilePath`, so a safe run can
  live in a shadow directory while still calling itself `Debian`.
- `VMDisk` enum → struct `{ kind: VMDiskKind, safe: Bool = true }`. A per-disk flag **cannot** be
  added to the current enum: it persists as `{"storage":{"_0":"disk","_1":0}}`, so a new associated
  value silently breaks every config. `VMDiskKind`'s synthesized encoding is byte-identical, making
  migration a fallback decode.
- `HostMountPoint` gains `safe: Bool = true`, and **`id` becomes persisted** — today it is
  regenerated on every load, so mount IDs survive only within one process while `removeMount`
  already depends on them.
- `StartPolicy { windowed, safe, autostart }` covers :4, :5, :17, :28 in one field.
- `totalRuntime` for the history view (:33).

**1.4 Engine errors keep their code.** `VirtualMachineError.critical` flattens to a generic
`internalError` at the server boundary; the MAC-conflict force flow needs a specific code.

---

## Phase 2 — pure view work

1. Symbol adoption across ~45 `systemName:` literals (:37, :29, :35), including `power` → gear for
   the default boot tab and `pc` → `macwindow`.
2. MAC row copy button (:24, first half).
3. Disks table copy-absolute-path column (:25) and tooltips on the type icons (:27).
4. **Host-mounts resize bug** (:31). Diagnosed: the `HStack` at `MainVMView.swift:32` is
   centre-aligned and its children have different vertical greed — `ConfigVMView` ends in a
   `Spacer()` so it fills the row, `ConfigVMHostMountsView` has neither `Spacer` nor height frame,
   so it shrinks and the slack splits above and below. Fix: `HStack(alignment: .top)`,
   `maxHeight: .infinity` on the right child, a trailing `Spacer()` inside it, and equalise the 2 pt
   padding the left column has and the right lacks.
5. History view redesign (:33): icons and tooltips, total alongside current uptime, `—` when
   stopped so the box doesn't resize.

---

## Phase 3 — wire surface

Each method costs six compiler-enforced sites plus `StubMachman`, fixtures and the protocol doc.
Hence four, not seven.

| method | params | result | routing |
|---|---|---|---|
| `vm.setStartPolicy` | `{name, policy}` | `{}` | proxy-if-hosted |
| `vm.setSafety` | `{name, disks:[id:Bool], mounts:[id:Bool]}` | `{}` | proxy-if-hosted |
| `vm.regenerateMAC` | `{name}` | `VMInfo` | refuse while hosted |
| `vm.copy` | `{name, newName?, diskIDs, regenerateMAC}` | `VMInfo` | refuse while hosted |

`VMInfo` gains `startPolicy`, `safeRun`, `DiskInfo.safe`, `MountInfo.safe` — all optional with
`decodeIfPresent`, per the `consoleOpen` precedent. Do **not** add cases to
`DiskType`/`BootInfo.Mode`/`StopMode`; those decoders are strict.

**MAC conflict + force** (:7) belongs in `RoutingMachman.start` — the only place with a global view.
`StartOptions` gains `force`; the refusal is a new `MachmanError.Code.macConflict`, wire-safe
because `Code` decodes tolerantly. Adding any field to `StartOptions` breaks
`WireFixtureTests.startOptionsDefaultsOnDecode` — an intended fixture update.

**The desktop has no error UI at all** (it prints `.log` events as a stopgap). The MAC-conflict
prompt is the forcing function: catch `MachmanError`, confirm, retry with `force`.

**Copy VM**: a sheet with a name field and checkboxes for *writable disks only* — ISOs are always
included by reference, mounts always copied, because only writable disks cost space. `clonefile`/
`copyfile` with `COPYFILE_CLONE`, in `MachmanCore/VMCopier.swift`, shared with safe mode as :9 asks.
A correct copy regenerates `vm_identifier` and, for macOS guests, `mac_machine_id`, and drops
`console.log`/`restore.ipsw`.

> `MachmanServer.handle` is `@MainActor` and awaits the engine, so a slow copy freezes every client.
> `clonefile` is O(1), but the cross-volume fallback is not — copy off the main actor or refuse.

---

## Phase 4 — run modes, autostart, icons, menus

1. **Run-defaults strip** (:28) between boot and hardware config: windowed/headless dropdown, safe
   checkbox, autostart checkbox, horizontal, icons + tooltips.
2. **Policy is applied by callers**, not the wire: `StartOptions.openConsole` keeps its meaning, and
   the Run button and each autostart agent read `startPolicy` and send explicit options.
3. **Autostart as a per-VM launchd agent** (:4) — deliberately not a daemon feature.
   - `MachmanCore/LaunchAgentManager.swift` writes
     `~/Library/LaunchAgents/<suite>.vm.<name>.plist`: the vmhost path plus `--data-dir`, `--vm`,
     `--socket`, `--display-name`, `--autostart`; `RunAtLoad`; `LimitLoadToSessionType = Aqua`
     (virtualizing and window-capable means an agent, never a system daemon); `MACHMAN_SUITE_ID` in
     the environment. Loaded with `launchctl bootstrap gui/$UID`.
   - **`KeepAlive` must be false** — the vmhost exits when its VM stops, so launchd would respawn it
     and the VM could never shut down.
   - **New `--autostart` flag on the vmhost**: today it waits for `vm.start` and exits after the
     180 s idle backstop, and under launchd nobody would call it.
   - The daemon stays optional: `adoptExistingHosts()` picks the VM up when it launches.
   - `setStartPolicy` installs/removes the agent; rename reinstalls under the new label; delete
     removes it.
   - SMAppService can't help — it only registers plists bundled inside the app, which cannot be
     per-VM. It *is* right for the menu-bar agent itself (0.2).
4. **Icon vocabulary** (:29): sidebar becomes `macwindow` blue / `terminal` blue / `pause.fill`,
   with a right-aligned yellow shield for a safe run; same status icon left of the large name in the
   VM view; icons into the Run/Stop/View menus and the menu-bar agent, which today shows only a
   filled-or-hollow circle.
5. **VM-window menu** (:6): `.accessory` → `.regular` while a console window exists. App menu titled
   with the VM name, View → Close Window, Stop → Shut Down / Force Stop. `spawnHost` passes
   `--display-name`, which is also what makes a safe run's title read correctly.
6. **Agent → open the desktop** (:39), a known relative path once both live in one bundle.

---

## Phase 5 — safe mode

1. **Shadow location** `<dataDir>/safe/<name>-<uuid>/` (:13) — works because `VMRegistry.scan`
   descends one level and `VMConfig(name: "safe")` throws, so the `try?` skips it. A sibling
   `<name>-safe-<uuid>` would be listed as a real VM. `directoryPath` (1.3) points at the shadow
   while `name` stays the display name.
2. **Creating it**: `VMCopier` with per-resource policy — `safe` disks cloned, `unsafe` disks
   referenced at their real path (:16), `safe` mounts omitted, `unsafe` mounts attached. ISOs always
   referenced.
3. **Running it**: `StartOptions.safe`. `RoutingMachman.start` builds the shadow, spawns a vmhost
   against it with the public display name, keys `hosted` by the display name. Outbound `VMInfo.name`
   and inbound event `vm:` are rewritten at the `route` seam from 1.2 — one place, not twenty.
4. **Save as a new VM** (:15): `vm.safeSave {name, newName}` promotes the shadow, re-keys `hosted`,
   marks the original stopped and the new VM running-and-not-safe. Its MAC changes on next start, so
   starting the original first requires `force` — the Phase 3 conflict path, and why it comes first.
   The vmhost's `VMRegistry(only:)` restriction has no mutator today and will need one.
5. **UI**: safe/unsafe flip-flop column in both tables (:26), shield in the sidebar row and header
   (:18, :29), File → Save as New VM… with a name prompt (:19).
6. **Cleanup**: discard the shadow in `hostGone`, and sweep `<dataDir>/safe/` at daemon start.

---

## Verification

```bash
xcodebuild build -project Machman.xcodeproj -scheme Machman-desktop \
  -destination 'platform=macOS' -derivedDataPath DerivedData 2>&1 \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
xcodebuild test -project Machman.xcodeproj -scheme Machman-desktop \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:MachmanTests 2>&1 | grep -E "Test case|TEST (SUCCEEDED|FAILED)"
```

Existing suites that pin the risky parts: `DataDirResolutionTests` (Debug and Release can never
resolve to the same library, and no socket path exceeds `sun_path`), `CrashRecoveryTests` (stale
sockets, atomic config, one damaged VM not hiding the rest), `WireFixtureTests` (wire shapes).

To add as the phases land: `VMDiskCodableTests` (the legacy `{"storage":{"_0":…}}` shape decodes
with `safe == true`; a mount's persisted `id` survives a reload) and `VMCopierTests` (a copy is
independent, has a new MAC and fresh `vm_identifier`, omits unchecked disks, references ISOs; a
safe-mode copy references `unsafe` disks and drops `safe` mounts).

Manual, per phase, in order: autostart is the one worth being strict about — toggle it on, **quit
the agent entirely**, `launchctl kickstart` the job, and confirm the VM comes up with no daemon
running; then launch the agent and confirm it adopts rather than spawning a second vmhost; then shut
the guest down and confirm launchd does not respawn it.
