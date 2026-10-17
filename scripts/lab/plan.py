#!/usr/bin/env python3
"""lab.sh's planner for a parallel run: which suites run, in what order, which alone.

  plan.py --list FILE [--filter REGEX] [--history FILE] [--exclusive FILE] [--sources DIR]
          --out DIR
  plan.py --record RUNS --history FILE
  plan.py --self-check

--list is the test ids, a line each (swift test list); the lab's tests are the
MachmanLabTests.* ids, and with --filter only those that `MachmanLabTests\\..*(REGEX)` finds,
as lab.sh filters a serial run. --out gets queue (the suites the workers share, longest first
by --history; a suite with no history goes first, as if long), serial (the --exclusive suites,
run alone after the queue), both as "<suite>\\t<--filter regex>" lines, planned (the test
count) and suites ("<suite>\\t<file>.swift:<line>\\t<tests>" for every planned suite: where
--sources declares it, so a suite that reports no test can fail at its place, Q27).
--record merges a run's "<suite>\\t<shard>\\t<status>\\t<seconds>" lines into --history (a
JSON object, suite -> seconds of its last run); a suite that ran no tests (status past 1: no
test matched, or the process died) leaves its time out.
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


def counts(listing, pattern):
    """suite -> how many of its tests the filter keeps."""
    found = {}
    for test in lab_ids(listing, pattern):
        suite = test.split("/", 1)[0].split(".", 1)[1]
        found[suite] = found.get(suite, 0) + 1
    return found


DECLARATION = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|final)\s+)*(?:struct|class|enum|actor)\s+"
    r"(\w+)\b")


def place(suites, sources):
    """suite -> "<file>.swift:<line>": the line of its @Suite attribute (where Swift Testing
    places a suite, even one spread over several lines), else of its declaration, in a Swift
    file under `sources`; a suite not found there is placed at "<suite>.swift:1", so a failure
    line at it still reads as a source location."""
    wanted, found = set(suites), {}
    for top, _, files in os.walk(sources) if sources else ():
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            lines = open(os.path.join(top, name), encoding="utf-8", errors="replace").readlines()
            for i, line in enumerate(lines):
                match = DECLARATION.match(line)
                if not match or match.group(1) not in wanted or match.group(1) in found:
                    continue
                at = i
                # Up through the attributes and their continuation lines, to a blank line, a
                # comment or the end of what came before.
                j = i - 1
                while j >= 0 and lines[j].strip() and not lines[j].lstrip().startswith(
                        ("//", "}", "import ")):
                    if lines[j].lstrip().startswith("@Suite"):
                        at = j
                    j -= 1
                found[match.group(1)] = "%s:%d" % (name, at + 1)
    return {s: found.get(s, "%s.swift:1" % s) for s in suites}


def write(out, queue, serial, planned, places=None, tests=None):
    os.makedirs(out, exist_ok=True)
    for name, rows in (("queue", queue), ("serial", serial)):
        with open(os.path.join(out, name), "w") as f:
            f.writelines("%s\t%s\n" % row for row in rows)
    with open(os.path.join(out, "planned"), "w") as f:
        f.write("%d\n" % planned)
    places = places or place([s for s, _ in queue + serial], None)
    with open(os.path.join(out, "suites"), "w") as f:
        f.writelines("%s\t%s\t%d\n" % (s, places[s], (tests or {}).get(s, 0))
                     for s, _ in queue + serial)


def record(runs, history_path):
    try:
        with open(history_path) as f:
            history = json.load(f)
    except (OSError, ValueError):
        history = {}
    for line in open(runs):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4 and parts[2] in ("0", "1"):
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
        with open(runs, "w") as f:
            f.write("FailTests\t1\t1\t12\nGoneTests\t2\t69\t1\nDeadTests\t1\t134\t3\n")
        record(runs, hist)
        check("a suite that ran no tests leaves its time out of the history (Q27)",
              json.load(open(hist)) == {"LongTests": 99.5, "FailTests": 12.0})
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "Engine"))
        with open(os.path.join(d, "Engine", "LongTests.swift"), "w") as f:
            f.write("import Testing\n\n// L2 — the long ones.\n@Suite(\n"
                    "\t\"Long\", .serialized)\n@MainActor\nstruct LongTests {\n"
                    "\t@Test func a() {}\n}\n")
        with open(os.path.join(d, "Short.swift"), "w") as f:
            f.write("// ShortTests: no attribute\nstruct ShortTests {\n}\n")
        places = place(["LongTests", "ShortTests", "NewTests"], d)
        check("a planned suite is placed at its @Suite line, else at its declaration (Q27)",
              places.get("LongTests") == "LongTests.swift:4"
              and places.get("ShortTests") == "Short.swift:2")
        check("a suite the sources don't declare is placed at <suite>.swift:1 (Q27)",
              places.get("NewTests") == "NewTests.swift:1")
        queue, serial, planned = plan(listing, None, history, {"EngineStallTests"})
        write(d, queue, serial, planned, place([s for s, _ in queue + serial], d),
              counts(listing, None))
        rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(d, "suites"))]
        check("the plan lists every planned suite with its place and test count (Q27)",
              ["LongTests", "LongTests.swift:4", "2"] in rows
              and ["EngineStallTests", "EngineStallTests.swift:1", "1"] in rows
              and len(rows) == 5)
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
    listing = open(arg("--list")).read()
    queue, serial, planned = plan(listing, arg("--filter"), history,
                                  exclusive(arg("--exclusive")))
    write(arg("--out"), queue, serial, planned,
          place([s for s, _ in queue + serial], arg("--sources")), counts(listing, arg("--filter")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
