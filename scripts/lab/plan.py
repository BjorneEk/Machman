#!/usr/bin/env python3
"""lab.sh's planner for a parallel run: which suites run, in what order, which alone.

  plan.py --list FILE [--filter REGEX] [--history FILE] [--exclusive FILE] --out DIR
  plan.py --record RUNS --history FILE
  plan.py --self-check

--list is `swift test list` output; the lab's tests are the MachmanLabTests.* ids, and with
--filter only those that `MachmanLabTests\\..*(REGEX)` finds, as lab.sh filters a serial run.
--out gets queue (the suites the workers share, longest first by --history; a suite with no
history goes first, as if long), serial (the --exclusive suites, run alone after the queue),
both as "<suite>\\t<swift test --filter regex>" lines, and planned (the test count).
--record merges a run's "<suite>\\t<shard>\\t<status>\\t<seconds>" lines into --history (a
JSON object, suite -> seconds of its last run).
"""
import json
import os
import re
import sys

UNKNOWN = 300.0  # seconds assumed for a suite with no history: it starts early


def lab_ids(listing, pattern):
    keep = re.compile(r"MachmanLabTests\..*(" + pattern + ")") if pattern else None
    ids = []
    for line in listing.splitlines():
        line = line.strip()
        if not line.startswith("MachmanLabTests.") or "/" not in line:
            continue
        if keep is None or keep.search(line):
            ids.append(line)
    return ids


def suites_of(ids, every):
    """suite -> its filter: the whole suite when every one of its tests is in, else the ids."""
    chosen = {}
    for test in ids:
        chosen.setdefault(test.split("/", 1)[0].split(".", 1)[1], []).append(test)
    out = {}
    for suite, tests in chosen.items():
        if len(tests) == len(every.get(suite, [])):
            out[suite] = r"MachmanLabTests\.%s/" % re.escape(suite)
        else:
            out[suite] = "|".join(re.escape(t) for t in tests)
    return out


def exclusive(path):
    names = set()
    if path and os.path.exists(path):
        for line in open(path):
            name = line.split("#", 1)[0].strip()
            if name:
                names.add(name)
    return names


def plan(listing, pattern, history, alone):
    all_ids = lab_ids(listing, None)
    every = {}
    for test in all_ids:
        every.setdefault(test.split("/", 1)[0].split(".", 1)[1], []).append(test)
    ids = lab_ids(listing, pattern)
    filters = suites_of(ids, every)
    order = sorted(filters, key=lambda s: (-history.get(s, UNKNOWN), s))
    queue = [(s, filters[s]) for s in order if s not in alone]
    serial = [(s, filters[s]) for s in order if s in alone]
    return queue, serial, len(ids)


def write(out, queue, serial, planned):
    os.makedirs(out, exist_ok=True)
    for name, rows in (("queue", queue), ("serial", serial)):
        with open(os.path.join(out, name), "w") as f:
            f.writelines("%s\t%s\n" % row for row in rows)
    with open(os.path.join(out, "planned"), "w") as f:
        f.write("%d\n" % planned)


def record(runs, history_path):
    try:
        with open(history_path) as f:
            history = json.load(f)
    except (OSError, ValueError):
        history = {}
    for line in open(runs):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4:
            try:
                history[parts[0]] = float(parts[3])
            except ValueError:
                pass
    os.makedirs(os.path.dirname(history_path) or ".", exist_ok=True)
    with open(history_path + ".tmp", "w") as f:
        json.dump(history, f, indent=1, sort_keys=True)
    os.replace(history_path + ".tmp", history_path)


def self_check():
    import tempfile
    fails = []

    def check(what, ok):
        print("%s  %s" % ("ok  " if ok else "FAIL", what))
        if not ok:
            fails.append(what)

    listing = "\n".join([
        "MachmanCoreTests.Other/x()",
        "MachmanLabTests.LongTests/a()", "MachmanLabTests.LongTests/b()",
        "MachmanLabTests.ShortTests/c()", "MachmanLabTests.NewTests/d()",
        "MachmanLabTests.EngineStallTests/e()", "MachmanLabTests.PartTests/f()",
        "MachmanLabTests.PartTests/g(x:)",
    ])
    history = {"LongTests": 120, "ShortTests": 5, "EngineStallTests": 30, "PartTests": 10}
    queue, serial, planned = plan(listing, None, history, {"EngineStallTests"})
    check("only the lab's tests are planned", planned == 7)
    check("the queue runs a suite with no history first, then the longest",
          [s for s, _ in queue] == ["NewTests", "LongTests", "PartTests", "ShortTests"])
    check("an exclusive suite runs alone, after the queue", [s for s, _ in serial]
          == ["EngineStallTests"])
    check("a whole suite is filtered by its name",
          dict(queue)["LongTests"] == r"MachmanLabTests\.LongTests/")
    queue, _, planned = plan(listing, "g\\(", history, set())
    check("a filter that keeps part of a suite names its tests",
          queue == [("PartTests", re.escape("MachmanLabTests.PartTests/g(x:)"))] and planned == 1)
    check("a part filter matches the test it names", re.search(
        queue[0][1], "MachmanLabTests.PartTests/g(x:)") is not None)
    with tempfile.TemporaryDirectory() as d:
        write(d, queue, [], 1)
        check("the queue file holds suite and filter",
              open(os.path.join(d, "queue")).read().startswith("PartTests\t"))
        runs = os.path.join(d, "runs.tsv")
        with open(runs, "w") as f:
            f.write("LongTests\t1\t0\t99.5\nbroken line\n")
        hist = os.path.join(d, "h", "suite-times.json")
        record(runs, hist)
        record(runs, hist)
        check("a run's suite times land in the history", json.load(open(hist)) == {
            "LongTests": 99.5})
    print("plan.py self-check: %s" % ("FAIL (%d)" % len(fails) if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) \
            else default
    if "--self-check" in argv:
        return self_check()
    if "--record" in argv:
        record(arg("--record"), arg("--history"))
        return 0
    if "--list" not in argv or "--out" not in argv:
        sys.stderr.write(__doc__)
        return 64
    try:
        with open(arg("--history", "")) as f:
            history = json.load(f)
    except (OSError, ValueError):
        history = {}
    queue, serial, planned = plan(open(arg("--list")).read(), arg("--filter"), history,
                                  exclusive(arg("--exclusive")))
    write(arg("--out"), queue, serial, planned)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
