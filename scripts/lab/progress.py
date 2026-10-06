#!/usr/bin/env python3
"""lab.sh's live progress: a run's Swift Testing event stream, its lab log and its console
transcripts as timestamped lines, while the run goes.

  progress.py --run ROOT [--level 0|1|2] [--stop FILE] [--stall SECONDS]
  progress.py --self-check

  level 0  each test's start, its end with its duration, its issues and known issues; a stall
           line after a minute without output (the running test, the step its harness
           narrates, the last console line); skips counted by reason at the end
  level 1  + each skip, suite starts and ends, and the lab log: agent, vmhost and harness
           lines, LabStep's narrations
  level 2  + the guest consoles, line by line

Inputs (lab.sh's run dir ROOT): report/events.jsonl (swift test --event-stream-output-path,
version 0), logs/unified.ndjson (log stream --style ndjson), transcripts/*.log, pids/*.pid.
Writes report/progress.log (level 2, whatever --level is) and report/test-times.tsv.
Stops when FILE exists and the inputs are drained; exit 0 when the run's summary came, 2 when
it never did (the test process crashed or was killed).
"""
import glob
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime

ESCAPES = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-Za-z]")
STEP = "lab: step "
SKIPPED = re.compile(r'^Test ".*?" skipped(?:: (.*?))?\.?$')
PROCESSES = {"MachmanAgent": "agent", "MachmanVMHost": "vmhost",
             "swiftpm-testing-helper": "test", "hostwatch": "audit"}


def clock(epoch):
    return time.strftime("%H:%M:%S", time.localtime(epoch))


def span(seconds):
    seconds = int(seconds)
    return "%d s" % seconds if seconds < 60 else "%dm%02ds" % (seconds // 60, seconds % 60)


def short_id(name):
    """The row or card id of "R2: …", else the whole name."""
    head = name.split(":", 1)[0]
    return head if ":" in name and head and len(head) <= 16 and " " not in head else name


def vm_of(pid):
    """The lab VM a vmhost serves, from its --vm argument (None once it has gone)."""
    try:
        args = subprocess.run(["/bin/ps", "-o", "args=", "-p", str(pid)], capture_output=True,
                              text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"--vm (.+?)(?= --|$)", args.strip())
    return match.group(1) if match else None


class Tail:
    """The complete lines a growing file gained since the last call. With `partial`, a last
    line that stopped growing for that long comes out too (a console prompt has no newline)."""

    def __init__(self, path, partial=None):
        self.path, self.partial = path, partial
        self.pos, self.rest, self.grew = 0, b"", 0.0

    def lines(self, now):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.pos)
                data = f.read()
        except OSError:
            return []
        self.pos += len(data)
        if data:
            self.grew = now
        parts = (self.rest + data).split(b"\n")
        self.rest = parts.pop()
        if self.rest and self.partial is not None and now - self.grew >= self.partial:
            parts.append(self.rest)
            self.rest = b""
        return parts


class Follower:
    def __init__(self, root, level, out, log, stall=60.0):
        self.root, self.level, self.out, self.log, self.stall = root, level, out, log, stall
        self.events = Tail(os.path.join(root, "report", "events.jsonl"))
        self.unified = Tail(os.path.join(root, "logs", "unified.ndjson"))
        self.consoles = {}
        self.plan, self.order = {}, []
        self.started = {}            # test id -> (index, start epoch)
        self.skipped = {}            # reason -> count
        self.issues = {}             # test id -> [(known, where)]
        self.results = []            # (id, display, status, seconds)
        self.current = None
        self.step = None             # (epoch, text) of the latest narration
        self.console = None          # (name, last line)
        self.pids = {}
        self.summary = None
        self.run_started = None
        self.printed = time.time()

    # --- output -----------------------------------------------------------------------------

    def emit(self, records):
        for epoch, level, text in sorted(records, key=lambda r: r[0]):
            # A multi-line message keeps the time column: its other lines are indented under it.
            rest = [l.rstrip() for l in text.split("\n")[1:] if l.strip()]
            if len(rest) > 12:
                rest = rest[:12] + ["… %d more lines" % (len(rest) - 12)]
            line = "%s %s" % (clock(epoch), text.split("\n", 1)[0].rstrip()) + "".join(
                "\n" + " " * 13 + l for l in rest)
            self.log.write(line + "\n")
            if level <= self.level:
                self.out.write(line + "\n")
                self.printed = time.time()
        self.out.flush()
        self.log.flush()

    # --- the event stream -------------------------------------------------------------------

    def display(self, test_id):
        return self.plan.get(test_id, test_id)

    def name(self, test_id):
        """The test's id, or its display name when other tests share that id (Q18)."""
        display = self.display(test_id)
        ident = short_id(display)
        shared = sum(1 for d in self.plan.values() if short_id(d) == ident) > 1
        return (display[:70] + ("…" if len(display) > 70 else "")) if shared else ident

    def of(self, index):
        """"5/184": the index among the planned tests not skipped so far."""
        return "%d/%d" % (index, len(self.plan) - sum(self.skipped.values()))

    def on_record(self, record, out):
        payload = record.get("payload", {})
        if record.get("kind") == "test":
            if payload.get("kind") == "function":
                self.plan[payload["id"]] = payload.get("displayName") or payload.get("name", "")
                self.order.append(payload["id"])
            return
        kind = payload.get("kind")
        when = payload.get("instant", {}).get("since1970", time.time())
        test_id = payload.get("testID")
        messages = payload.get("messages", [])
        first = messages[0]["text"] if messages else ""
        if kind == "runStarted":
            self.run_started = when
            out.append((when, 0, "lab: %d tests planned" % len(self.plan)))
        elif kind == "testStarted" and test_id in self.plan:
            index = len(self.started) + 1
            self.started[test_id] = (index, when)
            self.current = test_id
            out.append((when, 0, "▶ %s %s" % (self.of(index), self.display(test_id))))
        elif kind == "testStarted":
            out.append((when, 1, "· %s" % first))
        elif kind == "issueRecorded":
            issue = payload.get("issue", {})
            known = bool(issue.get("isKnown"))
            where = issue.get("sourceLocation", {})
            at = "%s:%s" % (os.path.basename(where.get("fileID", "?")), where.get("line", "?"))
            if test_id is not None:
                self.issues.setdefault(test_id, []).append((known, at))
            symbol = messages[0].get("symbol") if messages else ""
            glyph = "~" if known else ("!" if symbol == "warning" else "✘")
            text = " ".join(m["text"] for m in messages if m.get("text"))
            out.append((when, 0, "  %s %s: %s" % (glyph, at, text[:2000])))
        elif kind == "testSkipped" and test_id in self.plan:
            match = SKIPPED.match(first)
            reason = match.group(1) if match and match.group(1) else ""
            self.skipped[reason] = self.skipped.get(reason, 0) + 1
            self.results.append((test_id, self.display(test_id), "skipped", 0.0))
            out.append((when, 1, "– skip %s%s" % (
                self.display(test_id), (" — " + reason) if reason else "")))
        elif kind == "testSkipped":
            out.append((when, 1, "– %s" % first))
        elif kind == "testEnded" and test_id in self.started:
            index, start = self.started[test_id]
            seconds = when - start
            issues = self.issues.get(test_id, [])
            failed = any(not known for known, _ in issues) or any(
                m.get("symbol") == "fail" for m in messages)
            known = any(k for k, _ in issues)
            status = "failed" if failed else ("known issue" if known else "passed")
            glyph = "✘" if failed else "✔"
            note = " (known issue)" if known and not failed else ""
            self.results.append((test_id, self.display(test_id), status, seconds))
            out.append((when, 0, "%s %s %s · %s%s" % (
                glyph, self.of(index), self.name(test_id), span(seconds), note)))
            if self.current == test_id:
                self.current = None
        elif kind == "testEnded":
            out.append((when, 1, "· %s" % first))
        elif kind == "runEnded":
            self.summary = first
            out.append((when, 0, first))

    # --- the lab log and the consoles -------------------------------------------------------

    def who(self, entry):
        process = os.path.basename(entry.get("processImagePath") or "?")
        tag = PROCESSES.get(process, process[:12])
        pid = entry.get("processID")
        if tag == "vmhost" and pid is not None:
            if pid not in self.pids:
                vm = vm_of(pid)
                self.pids[pid] = "vmhost %s" % vm if vm else "vmhost %s" % pid
            tag = self.pids[pid]
        elif tag == "agent" and pid is not None:
            if pid not in self.pids:
                self.load_pids()
            tag = self.pids.get(pid, tag)
        return tag

    def load_pids(self):
        for path in glob.glob(os.path.join(self.root, "pids", "*.pid")):
            kind, _, name = os.path.basename(path)[:-4].partition("-")
            try:
                with open(path) as f:
                    pid = int(f.readline().strip())
            except (OSError, ValueError):
                continue
            self.pids[pid] = "%s %s" % (kind, name)

    def on_log(self, entry, out):
        message = entry.get("eventMessage", "")
        if "lab: log stream attached" in message:
            return
        try:
            when = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        except (KeyError, ValueError):
            when = time.time()
        text = re.sub(r"^\[log\] ", "", message)
        text = re.sub(r"^\[([a-z-]+)\] ", r"\1: ", text)
        if STEP in message:
            self.step = (when, message.split(STEP, 1)[1])
        out.append((when, 1, "  %-14s %s" % (self.who(entry), text[:2000])))

    def on_console(self, name, raw, now, out):
        line = ESCAPES.sub(b"", raw).replace(b"\r", b"").decode("utf-8", "replace").rstrip()
        if not line.strip():
            return
        self.console = (name, line.strip())
        out.append((now, 2, "  [%s] %s" % (name, line)))

    def stalled(self, now, out):
        if self.current is None or now - self.printed < self.stall:
            return
        index, start = self.started[self.current]
        parts = ["… %s %s running %s" % (
            self.of(index), self.name(self.current), span(now - start))]
        if self.step is not None and self.step[0] >= start:
            parts.append("step " + self.step[1])
        if self.console is not None:
            parts.append("[%s] %s" % (self.console[0], self.console[1][:120]))
        out.append((now, 0, " · ".join(parts)))
        self.printed = now

    # --- the loop ---------------------------------------------------------------------------

    def tick(self):
        now, out = time.time(), []
        for raw in self.events.lines(now):
            try:
                self.on_record(json.loads(raw), out)
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
        for raw in self.unified.lines(now):
            try:
                self.on_log(json.loads(raw), out)
            except (ValueError, AttributeError):
                continue
        for path in sorted(glob.glob(os.path.join(self.root, "transcripts", "*.log"))):
            tail = self.consoles.setdefault(path, Tail(path, partial=1.0))
            name = os.path.basename(path)[:-4]
            for raw in tail.lines(now):
                self.on_console(name, raw, now, out)
        self.emit(out)
        out = []
        self.stalled(now, out)
        self.emit(out)

    def finish(self):
        now, out = time.time(), []
        for path, tail in sorted(self.consoles.items()):
            if tail.rest:
                self.on_console(os.path.basename(path)[:-4], tail.rest, now, out)
                tail.rest = b""
        if self.summary is None:
            running = (" in %s" % self.name(self.current)) if self.current else ""
            out.append((now, 0, "lab: the test run ended without its summary%s" % running))
        counts = {}
        for _, _, status, _ in self.results:
            counts[status] = counts.get(status, 0) + 1
        ran = [r for r in self.results if r[2] != "skipped"]
        took = span(now - self.run_started) if self.run_started else "?"
        out.append((now, 0, "lab: %d tests · %s · %s" % (len(self.results), " · ".join(
            "%d %s" % (counts[s], s) for s in ("passed", "known issue", "failed", "skipped")
            if counts.get(s)) or "none ran", took)))
        if self.skipped:
            out.append((now, 0, "lab: skipped: " + " · ".join(
                "%d %s" % (n, reason or "(not in this run's tiers)") for reason, n in sorted(
                    self.skipped.items(), key=lambda item: -item[1]))))
        slowest = sorted(ran, key=lambda r: -r[3])[:5]
        if slowest:
            out.append((now, 0, "lab: slowest: " + " · ".join(
                "%s %s" % (self.name(r[0]), span(r[3])) for r in slowest)))
        failed = [r for r in ran if r[2] == "failed"]
        if failed:
            out.append((now, 0, "lab: failed: " + " · ".join(
                "%s (%s)" % (self.name(r[0]), ", ".join(
                    at for known, at in self.issues.get(r[0], []) if not known) or "?")
                for r in failed)))
        self.emit(out)
        with open(os.path.join(self.root, "report", "test-times.tsv"), "w") as f:
            f.write("seconds\tstatus\ttest\n")
            for _, name, status, seconds in sorted(self.results, key=lambda r: -r[3]):
                f.write("%.1f\t%s\t%s\n" % (seconds, status, name))
        return 0 if self.summary is not None else 2


def follow(root, level, stop, stall=60.0, interval=0.5, out=None):
    os.makedirs(os.path.join(root, "report"), exist_ok=True)
    with open(os.path.join(root, "report", "progress.log"), "a", buffering=1) as log:
        follower = Follower(root, level, out or sys.stdout, log, stall)
        while True:
            done = stop is not None and os.path.exists(stop)
            follower.tick()
            if done:
                follower.tick()
                return follower.finish()
            time.sleep(interval)


# --- self-check ----------------------------------------------------------------------------

def self_check():
    import io
    import tempfile

    fails = []

    def check(what, ok):
        print("%s  %s" % ("ok  " if ok else "FAIL", what))
        if not ok:
            fails.append(what)

    def test(display, name, line=10):
        return {"kind": "test", "version": 0, "payload": {
            "kind": "function", "id": "Mod.Suite/%s/File.swift:%d:3" % (name, line),
            "name": name, "displayName": display}}

    def event(kind, t, test_id=None, messages=(), **extra):
        payload = {"kind": kind, "instant": {"since1970": t}, "messages": [
            {"symbol": s, "text": x} for s, x in messages]}
        if test_id:
            payload["testID"] = test_id
        payload.update(extra)
        return {"kind": "event", "version": 0, "payload": payload}

    def write(path, records):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            for r in records:
                f.write((r if isinstance(r, str) else json.dumps(r)) + "\n")

    t0 = time.time() - 300
    r1 = "Mod.Suite/one()/File.swift:10:3"
    r2 = "Mod.Suite/two()/File.swift:20:3"
    r3 = "Mod.Suite/three()/File.swift:30:3"
    issue = {"isKnown": False, "sourceLocation": {"fileID": "Mod/File.swift", "line": 42}}
    known = {"isKnown": True, "sourceLocation": {"fileID": "Mod/File.swift", "line": 7}}
    stamp = datetime.fromtimestamp(t0 + 5).astimezone().strftime("%Y-%m-%d %H:%M:%S.%f%z")
    with tempfile.TemporaryDirectory() as root:
        write(root + "/report/events.jsonl", [
            test("R1: the first row", "one()"), test("E7: the second row", "two()", 20),
            test("a test without an id", "three()", 30),
            event("runStarted", t0, messages=[("default", "Test run started.")]),
            event("testStarted", t0 + 1, r1),
            event("issueRecorded", t0 + 2, r1, [("fail", "Expectation failed: 1 == 2\nsecond\n")],
                  issue=issue),
            event("testEnded", t0 + 70, r1, [("fail", 'Test "R1: the first row" failed.')]),
            event("testStarted", t0 + 71, r2),
            event("issueRecorded", t0 + 72, r2, [("pass", "Known issue: E7: a known one")],
                  issue=known),
            event("testSkipped", t0 + 73, r3,
                  [("skip", 'Test "a test without an id" skipped: "no image"')]),
            event("testSkipped", t0 + 73, "Mod.Other",
                  [("skip", 'Suite "Other" skipped.')]),
            event("testEnded", t0 + 75, r2, [("pass", "passed")]),
            event("runEnded", t0 + 77, messages=[
                ("fail", "Test run with 3 tests in 1 suite failed after 77 seconds.")]),
        ])
        write(root + "/pids/agent-03.pid", ["4242"])
        write(root + "/logs/unified.ndjson", [
            {"timestamp": stamp, "processImagePath": "/x/MachmanAgent", "processID": 4242,
             "eventMessage": "[log] serving machman.sock"},
            {"timestamp": stamp, "processImagePath": "/x/MachmanVMHost", "processID": 4243,
             "eventMessage": "[warning] gone already"},
            {"timestamp": stamp, "processImagePath": "/x/swiftpm-testing-helper",
             "processID": 1, "eventMessage": "[log] lab: step R1 ▸ waiting for login — 5 s"},
            "{not json",
        ])
        os.makedirs(root + "/transcripts")
        with open(root + "/transcripts/01-r1-hvc0.log", "wb") as f:
            f.write(b"\x1b[1mDebian GNU/Linux 13\x1b[0m\r\nlab-deb login: ")
        open(root + "/stop-now", "w").close()
        buf = io.StringIO()
        status = follow(root, 2, root + "/stop-now", interval=0.05, out=buf)
        text = buf.getvalue()
        check("a test's start reads its index, the plan's size and its display name",
              "▶ 1/3 R1: the first row" in text)
        check("a skip shrinks the plan's size", "▶ 2/3 E7: the second row" in text
              and "✔ 2/2 E7 · 4 s (known issue)" in text)
        check("a failed test reads ✘ with its id and duration", "✘ 1/3 R1 · 1m09s" in text)
        check("an issue reads its file:line and message, its other lines indented",
              "✘ File.swift:42: Expectation failed: 1 == 2\n" + " " * 13 + "second\n" in text)
        check("a known issue reads ~ and its test passes with a note",
              "~ File.swift:7:" in text and "(known issue)" in text)
        check("a skip reads its reason (level 1)",
              "– skip a test without an id — \"no image\"" in text)
        check("skips are counted by reason", 'lab: skipped: 1 "no image"' in text)
        check("the run's summary line is kept verbatim (igate greps it)",
              "Test run with 3 tests in 1 suite failed" in text)
        check("the closing summary counts and names the failure",
              "lab: 3 tests · 1 known issue · 1 failed · 1 skipped · " in text
              and "lab: failed: R1 (File.swift:42)" in text)
        check("an agent line carries its scope, a vmhost line its VM or pid",
              "agent 03       serving machman.sock" in text
              and "vmhost 4243    warning: gone already" in text)
        check("a suite's skip is no test", "lab: 3 tests ·" in text)
        check("a console's prompt comes out without a newline, escapes and CRs stripped",
              "[01-r1-hvc0] Debian GNU/Linux 13" in text and "[01-r1-hvc0] lab-deb login:" in text)
        check("a malformed log line is skipped", "not json" not in text)
        check("the run's summary came: exit 0", status == 0)
        with open(root + "/report/progress.log") as f:
            check("progress.log keeps the level-2 stream", "[01-r1-hvc0]" in f.read())
        with open(root + "/report/test-times.tsv") as f:
            rows = f.read().splitlines()
        check("test-times.tsv lists the slowest first",
              rows[0] == "seconds\tstatus\ttest" and rows[1].startswith("69.0\tfailed\tR1"))

    with tempfile.TemporaryDirectory() as root:
        write(root + "/report/events.jsonl", [
            test("R1: the first row", "one()"),
            event("runStarted", time.time() - 120),
            event("testStarted", time.time() - 100, r1),
        ])
        write(root + "/logs/unified.ndjson", [
            {"timestamp": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S.%f%z"),
             "processImagePath": "/x/swiftpm-testing-helper", "processID": 1,
             "eventMessage": "[log] lab: step R1 … hvc0: waiting ≤3m for /login/ — 45 s"}])
        quiet = io.StringIO()
        stop = root + "/stop"
        timer = threading.Timer(0.6, lambda: open(stop, "w").close())
        timer.start()
        status = follow(root, 0, stop, stall=0.2, interval=0.05, out=quiet)
        timer.join()
        text = quiet.getvalue()
        check("level 0 leaves the lab log out", "  test " not in text)
        check("a quiet run gets a stall line naming the test and its step",
              "… 1/1 R1 running" in text and "step R1 … hvc0: waiting ≤3m for /login/" in text)
        check("a run that never summarized says so and exits 2",
              "ended without its summary in R1" in text and status == 2)

    print("progress.py self-check: %s" % ("FAIL (%d)" % len(fails) if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    args = {"--level": "0", "--stall": "60"}
    i = 0
    while i < len(argv):
        if argv[i] == "--self-check":
            return self_check()
        if argv[i] in ("--run", "--level", "--stop", "--stall") and i + 1 < len(argv):
            args[argv[i]] = argv[i + 1]
            i += 2
            continue
        sys.stderr.write(__doc__)
        return 64
    if "--run" not in args:
        sys.stderr.write(__doc__)
        return 64
    try:
        return follow(args["--run"], int(args["--level"]), args.get("--stop"),
                      stall=float(args["--stall"]))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
