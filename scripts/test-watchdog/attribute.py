#!/usr/bin/env python3
"""Names the test each main-thread stall sample was in (Q43).

usage: python3 -I -B scripts/test-watchdog/attribute.py <test.sh log>...

Reads the PROBE lines the MM_WATCHDOG=1 watchdog (MachmanKit/Tests/MachmanTestGuard/
watchdog.c) wrote into scripts/test.sh logs, demangles each sample's frames with
`swift demangle --simplified`, and prints one row per test and blocking frame: how many
samples, the longest stall, the test (its innermost frame from a test module) and what the
main thread was in (a wait, a file call, a lock, else the top frame). Then the stalls: how
many reached 300 ms, their total and the longest. A measurement, never a check: a stall
under load says where the main thread went, not that a test failed.
"""

import collections
import re
import subprocess
import sys

BLOCKING = re.compile(
    r"waitUntilExit|NSLock|psynch|fsync|cksum|spinNested|getattrlist|__open|__rename|"
    r"__unlink|mkdir|read\(|write|usleep|sleep|fork|posix_spawn|mach_msg2")


def samples(path):
    """[(stalled ms, [frame symbol])] and [stall ms] from one log."""
    found, stalls, current = [], [], None
    with open(path, errors="replace") as log:
        for line in log:
            line = line.rstrip("\n")
            if line.startswith("PROBE sample"):
                ms = int(re.search(r"stalled (\d+) ms", line).group(1))
                current = (ms, [])
                found.append(current)
            elif line.startswith("PROBE   #") and current is not None:
                current[1].append(line.split(" ", 4)[-1])
            elif line.startswith("PROBE stall"):
                stalls.append(int(line.split()[3]))
                current = None
    return found, stalls


def demangled(names):
    if not names:
        return {}
    out = subprocess.run(
        ["swift", "demangle", "--simplified"], input="\n".join(names),
        capture_output=True, text=True).stdout.splitlines()
    return dict(zip(names, out))


def main(paths):
    if not paths:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    all_samples, all_stalls = [], []
    for path in paths:
        found, stalls = samples(path)
        all_samples += found
        all_stalls += stalls
    names = demangled(sorted({frame for _, frames in all_samples for frame in frames}))
    rows, worst = collections.Counter(), {}
    for ms, frames in all_samples:
        readable = [names.get(frame, frame) for frame in frames]
        test = next((frame for frame in readable
                     if re.search(r"Tests\b|Tests\.", frame) and "closure" not in frame
                     and "withRedirectedDir" not in frame and not frame.startswith("$s")),
                    None) or "runtime/other: " + " < ".join(f[:50] for f in readable[:3])
        what = next((frame for frame in readable if BLOCKING.search(frame)),
                    readable[0] if readable else "?")
        key = (test[:110], what[:60])
        rows[key] += 1
        worst[key] = max(worst.get(key, 0), ms)
    for (test, what), count in rows.most_common():
        print(f"{count:3d}  worst {worst[(test, what)]:5d} ms  {test}  ::  {what}")
    total = sum(all_stalls)
    longest = max(all_stalls, default=0)
    print(f"{len(all_stalls)} stalls >= 300 ms, {total} ms in all, the longest {longest} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
