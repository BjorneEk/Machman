# Testing Machman

Every behavior gets a test at the **lowest tier that can observe it**. A manual check is the
exception: it exists only when no tier can observe the behavior, and it says why ("Manual
because: …"). Nothing here ever launches a window, steals focus or writes the user's real
Machman data.

## The ladder: what you need to observe → tier

| You need to observe… | Tier | Run with |
|---|---|---|
| A pure rule, a parser, a config migration, a wire shape | **L1** unit | `scripts/test.sh` |
| What a view model decides: enablement, a confirmation, a toast, selection, routing | **L1** view model (`DesktopHarness` + `StubMachman`) | `scripts/test.sh` |
| What a view shows: labels, help, enabled-with-reason, menu contents, accessibility traits | **L1** offscreen view (`OffscreenHost` + `AXSnapshot`, `TreeMenuProbe`) | `scripts/test.sh` |
| A layout at a width, a colour scheme | **L1** render | `scripts/render.sh` |
| A rule over the repo: wording, schemes, build settings, test-mode seams | **L1** lint (`RepoFiles`) | `scripts/test.sh` |
| A connection loop against a misbehaving daemon | **L1** fake daemon (`FakeDaemon`) | `scripts/test.sh` |
| Real processes: the agent and vmhosts, sockets, crashes, restarts, prompts, version skew, disk and safe-run flows, a booted VM as an instrument | **L2** the lab (Alpine fixture) | `scripts/lab.sh` |
| What a guest OS does: Guest Setup's installer, logins on consoles, automounts, reboots, copied commands | **L3** lab guests (Debian, Debian-sysv, Alpine under VZ; FreeBSD under QEMU) | `scripts/lab.sh --guests` / `--full` |
| launchd: autostart jobs bootstrapped into gui/$UID | **L2** launchd tier (opt-in) | `scripts/lab.sh --launchd` |
| A live vmhost window, the keyboard, VoiceOver, a TCC prompt, a real log out, a macOS guest | manual | a row in `docs/local/manual-tests.md` with "Manual because: …" |

## Commands

```bash
scripts/test.sh [swift test args]        # L1: headless, per-run sandbox (/tmp/mmt.<token>)
scripts/test.sh --self-check             # proves the sandbox guard refuses unsandboxed runs
scripts/lab.sh --quick                   # L2 smoke: the lab agent + the Alpine fixture
scripts/lab.sh                           # L2: every lab suite but the guests
scripts/lab.sh --guests | --full         # L3 guests | everything (L2 + L3)
scripts/lab.sh --filter <TypeName>       # one suite (Swift Testing ids, never display names)
scripts/lab.sh --launchd                 # adds the launchd tier (off by default)
scripts/lab.sh … -v | -vv                # live progress + the lab log | + the guest consoles
scripts/lab.sh … --plain                 # timestamped lines on a terminal too
scripts/lab.sh … --jobs N                # at most N shards side by side (default: from the Mac)
scripts/lab.sh --doctor | --self-check   # tools, fixtures, seams | the lab's own audits proven
```

`test.sh` runs two `swift test` passes in one sandbox (the hosted MachmanDesktopUITests on their
own, so main-actor-heavy view tests never starve timing-sensitive engine tests) and keeps the
Mac awake for the run (`caffeinate -i -s`), as `lab.sh` does: a maintenance sleep mid-run reads
as dozens of timeouts.

`lab.sh` prints its progress live, read from Swift Testing's event stream (the test process
holds its own output back while it writes to a file), and names each test by what it does (the
`<id>: ` its name starts with is left out). On a terminal the running test sits in a block of
fixed height at the bottom (cursor hidden) with its elapsed time and the step its harness is
in; `-v` (the lab log) and `-vv` (the guest consoles too) fill it with a window of its output:
its first two lines, how many lines have gone by since, and the newest. Only a test's end
moves the screen: its result line, cut to the terminal's width (only its mark and number in
colour, its duration at the right edge), with its issues (laid out the same way; a known
issue by its title) or skip reason hung under it, dimmed (`├─`, `└─`). Piped, redirected or
with `--plain`, every line is printed with its time, and a quiet minute gets a stall line
naming the running test, its step and the last console line. Harness waits that run past 5 s
narrate themselves (`LabStep`). Every run keeps `report/progress.log` (the `-vv` stream) and
`report/test-times.tsv`; the sandbox goes at exit, so a run past the harness tier copies its
report, logs and transcripts to the lab cache's `last-run/` (the next run replaces it), and
`--out DIR` keeps a dated copy for good. A lab VM's start that fails in the engine (not a
guard's refusal) leaves `report/start-failures/<n>-<vm>.txt` — the error, each writable disk's
size, lock and holders, the VMs sharing it, the live Virtualization services and Virtualization's
own log — and a warning on its test; `lab.sh` names each record at the end. Lab VMs are named
for their role in the test, never after a row.

A run with L2 or L3 tests runs in parallel shards (`--jobs N`; by default a core each with two
left over and 5 GB of memory each past the first 8 GB, at most 8): each shard is a sandbox of
its own (suite token, agent, lab sshd, log), the suites are shared out longest first by the
times of earlier runs (`<cache>/suite-times.json`), and the suites in
`scripts/lab/exclusive-suites.txt` (machine-wide state, timing) run alone after them. One audit
watches every shard; on a terminal each shard has its own window in the block. Every test
process runs the one built test bundle through SwiftPM's testing helper, never through
`swift test`, whose build database a shard beside it can hold locked (shards once lost whole
suites to it); without the helper the run falls back to one `swift test` process and says why.
A planned suite that reports no test fails the run with a `✘ <file>.swift:<line>` line at its
`@Suite` (its exit status and first error beside it), and a `--filter` that matches no test
fails it too.

`lab.sh` builds THIS worktree's Debug products with `xcodebuild` (default DerivedData), mints
a sandbox (`/tmp/mml.<4-char token>`, suite `com.gustaffranzen.Machman.test-<token>`, a fake
home and library), holds the machine-wide lab slot, runs `MachmanLabTests` under the audits
and sweeps everything at exit. Fixtures (Alpine netboot kernel and initramfs, Debian 13 and
FreeBSD 14/15 cloud images, prepared images) are pinned by SHA-256 in `scripts/lab/*.lock` and
cached in the git-ignored `scripts/lab/cache/` (APFS clones between worktrees; each run boots
clones, never the cache). The vzfreebsd image is copied in by hand, never fetched or built:
`scripts/lab/guests/vzfreebsd/import.sh <a vzfreebsd checkout's work/out/release.raw>`; its
tests skip, naming that command, while the cache has none. `scripts/guest-regress/run.sh --backend docker|qemu|vz` runs the
guest-script suites in containers (Docker) or real VMs.

## One example per tier

**L1** (MachmanDesktopUITests/AccessibilityLabelTests.swift) — a hosted view read through
in-process accessibility, no window on screen:
`@Test("H39: a selected canvas tab reads as a selected button with Close Tab")`.

**L2** (MachmanLabTests/Engine/EngineStallTests.swift) — two Alpine VMs under the lab agent; one
vmhost is SIGSTOPped and the desktop's own view model must show it Not responding while the
other VM keeps updating:
`@Test("W1-21: a stopped vmhost reads not responding within 10 s while the other VM updates")`.

**L3** (MachmanLabTests/Guests/Setup/THConsoleLoginTests.swift) — Guest Setup's installer runs
in an Alpine guest over the console; the getty lines land between the markers and HUP brings
the login up: `@Test("G6: Alpine's getty lines sit between the markers and HUP brings the login up")`.

## The host-quiet contract (the lab's audits enforce it; a breach fails the run)

- No window, Dock icon or menu-bar item from any test process (window list and activation
  policy of every lab process sampled); a lab process never becomes frontmost or active; the
  pasteboard is never written (changeCount sampled; a change while one of the user's own apps
  is in front is only noted); no permission prompt (no audio devices, no screen capture, no TCP
  from a lab process to a guest on the VM network unless `MACHMAN_LAB_LOCAL_NETWORK=1`).
- Nothing real is written: the dev and Release data dirs, `~/.ssh`, `~/Library/LaunchAgents`
  and Machman's preference plists are snapshotted before and after every run; `~/.machman`
  (production) is never read.
- Test behavior exists only in Debug builds under a `.test-<token>` suite: one predicate,
  `MachmanTestMode`, and one reader of the lab's variables, `LabEnvironment`. Every product file
  that asks them is listed in `TestModeSeamInventoryTests` with a test proving the seam inert
  for the `.dev` and Release suites.
- Never from the main checkout; one lab run machine-wide (its shards side by side); at most 2
  guests per shard, ≤ 2 vCPU, ≤ 2 GB each. Opt-ins: `MACHMAN_LAB_LOCAL_NETWORK=1` (guest TCP), `MACHMAN_LAB_VOLUMES=0`
  (skip the disk-image volumes), `--launchd`.

## Naming and the manual-row rule

- `@Test("<card or row id>: <sentence>")`, e.g. `"E20: a stalled vmhost reads Not responding"`;
  infrastructure tests use the test system's card id.
- A test that shows an open bug FAILS until the fix lands; the check carries a comment
  "Fails until the open bug <card id> (<what>) is fixed", which the fix removes. A
  `withKnownIssue` is only for an issue someone actively deferred, and names that decision.
  A retry the harness rides over is recorded as a warning (`LabRetry.note`), never only logged.
- A fix commit names its test in a `Test: <name>` trailer.
- A manual row in `docs/local/manual-tests.md` carries **"Manual because: <reason>"** (or
  "Deferred: <tier>" for a tier not built yet). "Only a manual test can show this" is a claim to
  justify, not a default.
