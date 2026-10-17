#!/usr/bin/env python3
"""lab.sh's live progress: a run's Swift Testing event stream, its lab log and its console
transcripts, shown while the run goes. Tests are named by what they do: the "<id>: " their
names start with is left out.

  progress.py --run ROOT [--level 0|1|2] [--plain] [--stop FILE] [--stall SECONDS]
              [--shard ROOT … --planned N --suites FILE]
  progress.py --self-check

On a terminal (cursor hidden) a block of fixed height sits at the bottom: the running test
with its elapsed time, then the step its harness is in (level 0) or a window of its latest
output, padded with blank lines (levels 1 and 2). It changes in place; only a test's end moves
the screen, when its result line (cut to the terminal's width, with its issues, known issues
or skip reason as indented child lines) is printed above the block. Piped, redirected or with
--plain, everything is a timestamped line, and a quiet minute gets a stall line naming the
running test, its step and the last console line.

  level 0  each test's result (duration, issues, known issues); skips counted at the end
  level 1  + each skip, suite starts and ends, the lab log (agent, vmhost and harness lines,
           the harness's narrated waits)
  level 2  + the guest consoles, line by line

Inputs (lab.sh's run dir ROOT): report/events.jsonl (the test process's
--event-stream-output-path, version 6.3 with the experimental fields on: warnings, and the
argument of a parameterized test's issue, Q42), logs/unified.ndjson (log stream --style ndjson),
transcripts/*.log, pids/*.pid. A parallel run (--shard, --planned) reads each shard's
report/events/<suite>.jsonl; with --suites (plan.py's suites file) a planned suite that reported
no test is a failure line at its place, with its exit status (ROOT's report/suite-runs.tsv) and
the error its output (a shard's report/runs/<suite>.log) gave (Q27).
Writes report/progress.log (level 2, plain, whatever --level is) and report/test-times.tsv.
Stops when FILE exists and the inputs are drained; exit 0 when the run's summary came, 2 when
it never did (the test process crashed or was killed), 3 when a planned suite reported no test
(whatever its process's exit status: lab.sh fails the run on it, Q27).
"""
import collections
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

ESCAPES = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-Za-z]")
CONTROLS = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
# A row or card id a known issue's title starts with ("V14: ", "R3W2-24: "): it has a digit.
CARD = re.compile(r"\b(?=[A-Z0-9-]*\d)[A-Z][A-Z0-9]*(?:-\d+[a-z]?)?: ")
STEP = "lab: step "
SKIPPED = re.compile(r'^Test ".*?" skipped(?:: (.*?))?\.?$')
CONSOLE = re.compile(r"^(.+?)-(hvc\d+|ttyV[\d.]*|ttyVI\d+|ttyu\d+|serial|uart\d*|ssh)$")
PROCESSES = {"MachmanAgent": "agent", "MachmanVMHost": "vmhost",
             "swiftpm-testing-helper": "test", "hostwatch": "audit"}

# A record: (epoch, level, text, role[, extras]). Roles: "result" stays on screen; "issue" is a
# test's issue (a line when plain; on a terminal a child line under the test's result);
# "start" is a test's start (a line when plain, the block's header on a terminal); "detail"
# and "step" (a narrated wait) are output (lines when plain, the block's window on a
# terminal); "stall" is plain only. Extras, for the terminal: "parts" (mark, name, suffix:
# the name is what gets cut to fit), "note" (a yellow suffix), "children" (items hung under
# the line: glyph, text, more lines), "test".


def clock(epoch):
    return time.strftime("%H:%M:%S", time.localtime(epoch))


def span(seconds):
    seconds = int(seconds)
    return "%d s" % seconds if seconds < 60 else "%dm%02ds" % (seconds // 60, seconds % 60)


def about(display):
    """What a test does: its display name without the "<id>: " it starts with or an id tag
    like " (TB14)" it ends with."""
    head, sep, rest = display.partition(": ")
    if sep and head and len(head) <= 16 and " " not in head and rest:
        display = rest
    return re.sub(r" \([A-Z]{1,3}\d+[a-z]?\)$", "", display)


def console_title(name):
    """A transcript's name as "<vm> <console>" (scope numbers, counters and retries left out)."""
    name = re.sub(r"^(th|qemu)-", "", name)
    name = re.sub(r"^\d+-", "", name)
    name = re.sub(r"(-(try|boot)\d+|-again|-[0-9a-fA-F]{6,}|-\d+)+$", "", name)
    match = CONSOLE.match(name)
    return "%s %s" % match.groups() if match else name


def vm_of(pid):
    """The lab VM a vmhost serves, from its --vm argument (None once it has gone)."""
    try:
        args = subprocess.run(["/bin/ps", "-o", "args=", "-p", str(pid)], capture_output=True,
                              text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"--vm (.+?)(?= --|$)", args.strip())
    return match.group(1) if match else None


def gap(skipped, where=""):
    """The line that stands for `skipped` lines left out."""
    return "⋯ %d more line%s%s ⋯" % (skipped, "" if skipped == 1 else "s", where)


def elide(lines, height, where=""):
    """At most `height` lines: all of them when they fit, else the first two, a line saying
    how many are left out, and the newest below it."""
    if len(lines) <= height:
        return list(lines)
    tail = height - 3
    return list(lines[:2]) + [gap(len(lines) - 2 - tail, where)] + list(lines[-tail:])


def fit(text, width):
    text = CONTROLS.sub("", text.expandtabs(4))
    return text if len(text) <= width else text[:max(1, width - 1)] + "…"


class Tail:
    """The complete lines a growing file gained since the last call. With `partial`, a last
    line that stopped growing for that long comes out too (a console prompt has no newline)."""

    def __init__(self, path, partial=None):
        self.path, self.partial = path, partial
        self.pos, self.rest, self.grew = 0, b"", 0.0
        try:
            self.born = os.stat(path).st_birthtime
        except (OSError, AttributeError):
            self.born = None

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


class Window:
    """A running test's output for the block: its first two lines, the newest, and how many
    it has had."""

    def __init__(self):
        self.head, self.tail, self.count = [], collections.deque(maxlen=64), 0

    def add(self, stamp, text):
        """A line of output and its time ("" for a message's further lines)."""
        if len(self.head) < 2:
            self.head.append((stamp, text))
        self.tail.append((stamp, text))
        self.count += 1

    def lines(self, height):
        """(time, text) pairs, at most `height`."""
        if self.count <= height:
            return list(self.tail)[-self.count:] if self.count else []
        newest = list(self.tail)[-(height - 3):]
        return self.head + [("", gap(self.count - 2 - len(newest)))] + newest


class Screen:
    """The live block at the bottom of a terminal, rewritten in place: erase it, print what
    stays above it, draw it again."""

    def __init__(self, out, colour, size=None):
        self.out, self.colour, self.size = out, colour, size
        self.drawn, self.last, self.hidden = 0, None, False

    def dimensions(self):
        if self.size is not None:
            return self.size
        size = shutil.get_terminal_size((100, 30))
        return max(40, size.columns), max(10, size.lines)

    def paint(self, code, text):
        return "\x1b[%sm%s\x1b[0m" % (code, text) if self.colour and code else text

    def render(self, row, width):
        """A row: (colour code, text) segments cut to `width` with an ellipsis, and an
        optional (code, text) right-aligned at the edge: ([segments], right or None)."""
        segments, right = row
        room = width - (len(right[1]) + 2 if right else 0)
        out, used = [], 0
        for code, text in segments:
            text = CONTROLS.sub("", text.expandtabs(4))
            if used + len(text) > room:
                text = text[:max(0, room - used - 1)] + "…"
                out.append(self.paint(code, text))
                used += len(text)
                break
            out.append(self.paint(code, text))
            used += len(text)
        if right:
            out.append(" " * (width - used - len(right[1])) + self.paint(*right))
        return "".join(out)

    def update(self, above, block):
        """`above` and `block` are rows (see render)."""
        if not above and block == self.last:
            return
        width = self.dimensions()[0] - 1
        parts = ["\x1b[?2026h"]  # synchronized update, where the terminal knows it
        if block and not self.hidden:
            parts.append("\x1b[?25l")
            self.hidden = True
        if self.drawn:
            parts.append("\r\x1b[%dA\x1b[J" % self.drawn)
        parts.extend(self.render(row, width) + "\n" for row in above + block)
        if not block and self.hidden:
            parts.append("\x1b[?25h")
            self.hidden = False
        parts.append("\x1b[?2026l")
        self.out.write("".join(parts))
        self.out.flush()
        self.drawn, self.last = len(block), block


class Lane:
    """One shard of a run (a serial run is one): its sandbox's event streams (one per swift
    test process), lab log and consoles, and the test it runs now with that test's output."""

    def __init__(self, index, root):
        self.index, self.root = index, root
        self.streams, self.ended = {}, {}
        self.unified = Tail(os.path.join(root, "logs", "unified.ndjson"))
        self.consoles = {}
        self.current = None
        self.step = None             # (epoch, text) of the latest narration
        self.console = None          # (title, last line)
        self.window = Window()

    def event_files(self):
        single = os.path.join(self.root, "report", "events.jsonl")
        files = [single] if os.path.exists(single) else []
        return files + sorted(glob.glob(os.path.join(self.root, "report", "events", "*.jsonl")))


class Follower:
    def __init__(self, roots, level, out, log, stall=60.0, tty=False, size=None,
                 planned=None, suites=None):
        roots = [roots] if isinstance(roots, str) else list(roots)
        self.root, self.level, self.out, self.log, self.stall = roots[0], level, out, log, stall
        self.screen = Screen(out, "NO_COLOR" not in os.environ, size) if tty else None
        self.lanes = [Lane(i, r) for i, r in enumerate(roots)]
        self.lane = self.lanes[0]    # the lane whose inputs are being read
        self.parallel = planned is not None
        self.planned = planned
        self.announced = False
        self.plan = {}
        self.suites = {}             # suite id -> display name
        self.started = {}            # test id -> (index, start epoch)
        self.skipped = {}            # reason -> count
        self.issues = {}             # test id -> [(known, where)]
        self.details = {}            # test id -> [(glyph, where, text, known issue's title)]
        self.done = False
        self.results = []            # (id, about, status, seconds)
        self.pids = {}
        self.summary = None
        self.run_started = None
        self.printed = time.time()
        self.reported = set()        # suites that reported a test (ended or skipped)
        self.planned_suites = []     # (suite, place) of a parallel run's plan
        if suites and os.path.exists(suites):
            for row in open(suites):
                parts = row.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[0]:
                    self.planned_suites.append((parts[0], parts[1]))

    # The test the lane being read runs, its step, its last console line and its window.
    current = property(lambda self: self.lane.current,
                       lambda self, v: setattr(self.lane, "current", v))
    step = property(lambda self: self.lane.step, lambda self, v: setattr(self.lane, "step", v))
    console = property(lambda self: self.lane.console,
                       lambda self, v: setattr(self.lane, "console", v))
    window = property(lambda self: self.lane.window,
                      lambda self, v: setattr(self.lane, "window", v))

    # --- output -----------------------------------------------------------------------------

    def line(self, epoch, text):
        # A multi-line message keeps the time column: its other lines are indented under it.
        rest = [l.rstrip() for l in text.split("\n")[1:] if l.strip()]
        if len(rest) > 12:
            rest = rest[:12] + ["… %d more lines" % (len(rest) - 12)]
        return "%s %s" % (clock(epoch), text.split("\n", 1)[0].rstrip()) + "".join(
            "\n" + " " * 13 + l for l in rest)

    def emit(self, records, now):
        above = []
        for record in sorted(records, key=lambda r: r[0]):
            epoch, level, text, role = record[:4]
            extras = record[4] if len(record) > 4 else {}
            lane = self.lanes[extras.get("lane", 0)]
            if self.parallel and role in ("detail", "step"):
                # The shard a line comes from, where lines of several interleave.
                line = self.line(epoch, "  %d│%s" % (lane.index + 1, text.strip()))
            else:
                line = self.line(epoch, text)
            self.log.write(line + "\n")
            if self.screen is None:
                if level <= self.level:
                    above.append(line)
            elif role == "issue" and extras.get("test") in self.plan:
                pass  # a child line under the test's result
            elif role in ("result", "issue") and level <= self.level:
                above.extend(self.rows(epoch, text, extras))
            elif role in ("detail", "step") and level <= self.level and (
                    lane.current is None or min(epoch, extras.get("born") or epoch)
                    >= self.started[lane.current][1]):
                # (A line older than the running test, or from a console opened before it,
                # is the last test's, late.)
                parts = text.strip().split("\n")
                lane.window.add(clock(epoch), parts[0].rstrip())
                for part in parts[1:]:
                    if part.strip():
                        lane.window.add("", " " * 9 + part.strip())
        self.log.flush()
        if self.screen is None:
            if above:
                self.out.write("".join(l + "\n" for l in above))
                self.out.flush()
                self.printed = now
        else:
            self.screen.update(above, self.block(now))

    @staticmethod
    def colour(text):
        return {"✔": "32", "✘": "1;31", "~": "33", "!": "33", "–": "2"}.get(text.lstrip()[:1])

    def rows(self, epoch, text, extras):
        """A result's rows on the terminal: its line (its time dim, only the mark and index
        coloured, a note yellow, its duration dim at the right edge), then its children hung
        under it, dim but for their glyph and what they start with."""
        stamp = ("2", clock(epoch) + " ")
        lines = [l.rstrip() for l in text.split("\n")]
        right = None
        if "parts" in extras:
            mark, name, tail = extras["parts"]
            note = extras.get("note", "")
            took = tail.strip(" ·")
            right = ("2", took) if took else None
            room = self.screen.dimensions()[0] - 1 - len(stamp[1] + mark + " " + note) \
                - (len(took) + 2 if took else 0)
            name = fit(name, max(10, room))
            if mark.startswith("–"):
                left = [stamp, ("2", "%s %s" % (mark, name))]
            else:
                left = [stamp, (self.colour(mark), mark), (None, " " + name)]
                if note:
                    left.append(("33", note))
        else:
            left = [stamp, (self.colour(lines[0]), lines[0].strip())]
        rows = [(left, right)]
        items = extras.get("children")
        if items is None:
            rows.extend(([(None, " " * 9 + l.strip())], None) for l in lines[1:] if l.strip())
            return rows
        for i, (glyph, line, more) in enumerate(items):
            last = i == len(items) - 1
            lead = [(None, " " * 9), ("2", "└─ " if last else "├─ ")]
            if glyph:
                lead += [(self.colour(glyph), glyph), (None, " ")]
            head, sep, rest = line.partition(": ")
            if sep:
                lead += [("33" if glyph == "~" else "1", head + ":"), ("2", " " + rest)]
            else:
                lead.append(("2", line))
            rows.append((lead, None))
            for l in more:
                rows.append(([(None, " " * 9), ("2", ("   " if last else "│  ") + "  " + l)],
                             None))
        return rows

    def children(self, test_id):
        """A test's issues as items to hang under its result: a failure's message (8 lines at
        most: its first two, how many are left out, its last five), a known issue's title."""
        out = []
        for glyph, at, text, title in self.details.get(test_id, []):
            lines = [l.strip() for l in text.split("\n") if l.strip()] or [""]
            if glyph == "~":
                out.append((glyph, "known issue: %s" % (title or lines[0]), []))
                continue
            lines[0] = "%s: %s" % (at, lines[0])
            shown = elide(lines, 8, " in report/progress.log")
            out.append((glyph, shown[0], shown[1:]))
        return out

    def block(self, now):
        """The live block, the same height from the first test to the last: per shard, its
        running test's header, then its step (level 0) or a window of its latest output
        (levels 1 and 2), padded with blank lines; an idle shard's block stays, empty."""
        if self.done:
            return []
        rows_on_screen, lanes = self.screen.dimensions()[1], len(self.lanes)
        if self.level == 0:
            height = 1
        elif lanes == 1:
            height = min(10, max(3, rows_on_screen // 3))
        else:
            height = max(2, min(10, rows_on_screen // 2 // lanes - 1))
        rows = []
        for lane in self.lanes:
            rows.append(self.header(lane, now))
            body = []
            if self.level == 0:
                if lane.current is not None and lane.step is not None \
                        and lane.step[0] >= self.started[lane.current][1] \
                        and not lane.step[1].startswith(("✓", "✘")):
                    body.append(([("2", "  " + lane.step[1])], None))
            elif lane.current is not None:
                body.extend(([("2", "  " + (stamp + " " if stamp else "") + text)], None)
                            for stamp, text in lane.window.lines(height))
            rows.extend(body + [([("2", "")], None)] * (height - len(body)))
        return rows

    def header(self, lane, now):
        if lane.current is not None:
            index, start = self.started[lane.current]
            took = span(now - start)
            room = self.screen.dimensions()[0] - 1 - len("▶ %s " % self.of(index)) - len(took) - 2
            return ([("1", "▶ %s %s" % (self.of(index), fit(
                self.name(lane.current), max(10, room))))], ("2", took))
        if len(self.lanes) > 1:
            return ([("2", "· idle")], None)
        if self.started:
            return ([("1", "▶ between tests")], None)
        return ([("1", "▶ starting the test run")], None)

    # --- the event stream -------------------------------------------------------------------

    def display(self, test_id):
        return self.plan.get(test_id, test_id)

    def name(self, test_id):
        """What a test does — and, when another planned test does the same in another suite
        (one row run per guest OS), which suite this one is: "… (Debian read-only rows)"."""
        own = about(self.display(test_id))
        if not any(t != test_id and about(n) == own for t, n in self.plan.items()):
            return own
        suite = self.suites.get(test_id.rsplit("/", 2)[0], "")
        label = suite.rpartition(" — ")[2]
        return "%s (%s)" % (own, label) if label else own

    def of(self, index):
        """"5/184": the index among the planned tests not skipped so far."""
        return "%d/%d" % (index, max(self.planned or 0, len(self.plan))
                          - sum(self.skipped.values()))

    def on_record(self, record, out, stream=None):
        payload = record.get("payload", {})
        if record.get("kind") == "test":
            if payload.get("kind") == "function":
                self.plan[payload["id"]] = payload.get("displayName") or payload.get("name", "")
            elif payload.get("kind") == "suite":
                self.suites[payload["id"]] = payload.get("displayName") or payload.get("name", "")
            return
        kind = payload.get("kind")
        when = payload.get("instant", {}).get("since1970", time.time())
        test_id = payload.get("testID")
        messages = payload.get("messages", [])
        first = messages[0]["text"] if messages else ""
        if kind in ("testEnded", "testSkipped") and test_id:
            self.reported.add(test_id.split("/", 1)[0].split(".", 1)[-1])
        if kind == "runStarted" and self.parallel:
            self.run_started = self.run_started or when
        elif kind == "runStarted":
            self.run_started = when
            out.append((when, 0, "lab: %d test%s planned" % (
                len(self.plan), "" if len(self.plan) == 1 else "s"), "result"))
        elif kind == "testStarted" and test_id in self.plan:
            index = len(self.started) + 1
            self.started[test_id] = (index, when)
            self.current = test_id
            self.window = Window()
            out.append((when, 0, "▶ %s %s" % (self.of(index), self.name(test_id)),
                        "start"))
        elif kind == "testStarted":
            out.append((when, 1, "· %s" % first, "detail"))
        elif kind == "issueRecorded":
            issue = payload.get("issue", {})
            known = bool(issue.get("isKnown"))
            where = issue.get("sourceLocation", {})
            at = "%s:%s" % (os.path.basename(where.get("fileID", "?")), where.get("line", "?"))
            # A parameterized test's issue names the argument it failed with: "[debian]".
            case = (payload.get("_testCase") or {}).get("displayName")
            if case:
                at += " [%s]" % case
            symbol = messages[0].get("symbol") if messages else ""
            glyph = "~" if known else ("!" if symbol == "warning" else "✘")
            texts = [m["text"] for m in messages if m.get("text")]
            # An issue recorded with only a comment: Swift Testing's placeholder, then the comment.
            if len(texts) > 1 and texts[0] == "Issue recorded":
                texts = texts[1:]
            text = CARD.sub("", " ".join(texts))
            title = CARD.sub("", next((m.get("text", "") for m in messages[1:]
                                      if m.get("symbol") == "details"), ""))
            if test_id is not None:
                if glyph != "!":  # a warning never fails its test
                    self.issues.setdefault(test_id, []).append((known, at))
                self.details.setdefault(test_id, []).append((glyph, at, text[:2000], title))
            out.append((when, 0, "  %s %s: %s" % (glyph, at, text[:2000]), "issue",
                        {"test": test_id}))
        elif kind == "testSkipped" and test_id in self.plan:
            match = SKIPPED.match(first)
            reason = match.group(1) if match and match.group(1) else ""
            self.skipped[reason] = self.skipped.get(reason, 0) + 1
            self.results.append((test_id, self.name(test_id), "skipped", 0.0))
            # A skip with a reason says something (-v); one for a tier not in this run doesn't.
            out.append((when, 1 if reason else 2, "– skipped: %s%s" % (
                self.name(test_id), (" — " + reason) if reason else ""), "result",
                {"parts": ("– skipped:", self.name(test_id), ""),
                 "children": [("", reason.strip('"'), [])] if reason else []}))
        elif kind == "testSkipped":
            match = SKIPPED.match(first.replace("Suite", "Test", 1))
            out.append((when, 1 if match and match.group(1) else 2, "– %s" % first, "result"))
        elif kind == "testEnded" and test_id in self.started:
            index, start = self.started[test_id]
            seconds = when - start
            issues = self.issues.get(test_id, [])
            failed = any(not known for known, _ in issues) or any(
                m.get("symbol") == "fail" for m in messages)
            known = any(k for k, _ in issues)
            status = "failed" if failed else ("known issue" if known else "passed")
            note = " · known issue" if known and not failed else ""
            self.results.append((test_id, self.name(test_id), status, seconds))
            glyph = "✘" if failed else "✔"
            out.append((when, 0, "%s %s %s · %s%s" % (
                glyph, self.of(index), self.name(test_id), span(seconds), note),
                "result", {"parts": ("%s %s" % (glyph, self.of(index)),
                                     self.name(test_id), " · %s" % span(seconds)),
                           "note": note, "children": self.children(test_id)}))
            if self.current == test_id:
                self.current = None
                self.window = Window()
        elif kind == "testEnded":
            out.append((when, 1, "· %s" % first, "detail"))
        elif kind == "runEnded":
            self.lane.ended[stream] = True
            if self.parallel:
                out.append((when, 2, "· %s" % first, "detail"))
            else:
                self.summary = first
                out.append((when, 0, first, "result"))

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
        for path in [p for lane in self.lanes
                     for p in glob.glob(os.path.join(lane.root, "pids", "*.pid"))]:
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
        if STEP in message:
            self.step = (when, message.split(STEP, 1)[1])
            out.append((when, 1, "  step %s" % self.step[1], "step"))
            return
        text = re.sub(r"^\[log\] ", "", message)
        text = re.sub(r"^\[([a-z-]+)\] ", r"\1: ", text)
        out.append((when, 1, "  %-14s %s" % (self.who(entry), text[:2000]), "detail"))

    def on_console(self, name, raw, now, out, born=None):
        line = ESCAPES.sub(b"", raw).replace(b"\r", b"").decode("utf-8", "replace").rstrip()
        if not line.strip():
            return
        title = console_title(name)
        self.console = (title, line.strip())
        out.append((now, 2, "  [%s] %s" % (title, line), "detail", {"born": born}))

    def stalled(self, now, out):
        if self.screen is not None or now - self.printed < self.stall:
            return
        for lane in self.lanes:
            if lane.current is None:
                continue
            index, start = self.started[lane.current]
            parts = ["… %s %s · running %s" % (
                self.of(index), self.name(lane.current), span(now - start))]
            if lane.step is not None and lane.step[0] >= start:
                parts.append("step " + lane.step[1])
            if lane.console is not None:
                parts.append("[%s] %s" % (lane.console[0], lane.console[1][:120]))
            out.append((now, 0, " · ".join(parts), "stall"))

    # --- the loop ---------------------------------------------------------------------------

    def tick(self):
        now, out = time.time(), []
        if self.parallel and not self.announced:
            self.announced = True
            out.append((now, 0, "lab: %d test%s planned · %d shards" % (
                self.planned, "" if self.planned == 1 else "s", len(self.lanes)), "result"))
        for lane in self.lanes:
            self.lane, read = lane, []
            for path in lane.event_files():
                lane.ended.setdefault(path, False)
                tail = lane.streams.setdefault(path, Tail(path))
                for raw in tail.lines(now):
                    try:
                        self.on_record(json.loads(raw), read, path)
                    except (ValueError, KeyError, TypeError, AttributeError):
                        continue
            for raw in lane.unified.lines(now):
                try:
                    self.on_log(json.loads(raw), read)
                except (ValueError, AttributeError):
                    continue
            for path in sorted(glob.glob(os.path.join(lane.root, "transcripts", "*.log"))):
                tail = lane.consoles.setdefault(path, Tail(path, partial=1.0))
                for raw in tail.lines(now):
                    self.on_console(os.path.basename(path)[:-4], raw, now, read, tail.born)
            out.extend(r[:4] + (dict(r[4] if len(r) > 4 else {}, lane=lane.index),)
                       for r in read)
        self.lane = self.lanes[0]
        self.stalled(now, out)
        self.emit(out, now)

    def close(self):
        """Takes the live block off the screen and shows the cursor again (an interrupted run
        leaves no half block)."""
        self.done = True
        if self.screen is not None and (self.screen.drawn or self.screen.hidden):
            self.screen.last = None
            self.screen.update([], [])

    def why_empty(self, suite):
        """Why a suite reported no test: its test process's exit status and the first error its
        output gave (SwiftPM's "unable to attach DB" once lost whole suites, Q27)."""
        status = None
        runs = os.path.join(self.root, "report", "suite-runs.tsv")
        if os.path.exists(runs):
            for row in open(runs):
                parts = row.rstrip("\n").split("\t")
                if len(parts) == 4 and parts[0] == suite:
                    status = parts[2]
        why = "its test process left no exit status" if status is None else \
            "test exit %s%s" % (status, " (no test matched its filter)" if status == "69" else "")
        for lane in self.lanes:
            log = os.path.join(lane.root, "report", "runs", suite + ".log")
            if not os.path.exists(log):
                continue
            for line in open(log, errors="replace"):
                match = re.search(r"(error: .*|MachmanTestGuard: .*|Fatal error: .*)", line)
                if match:
                    return "%s: %s" % (why, fit(match.group(1).strip(), 300))
        return why

    def finish(self):
        now, out = time.time(), []
        unfinished = []
        for lane in self.lanes:
            self.lane = lane
            for path, tail in sorted(lane.consoles.items()):
                if tail.rest:
                    self.on_console(os.path.basename(path)[:-4], tail.rest, now, out)
                    tail.rest = b""
            running, lane.current = lane.current, None
            if running is not None:
                # The test process died in it: its issues never got a result line to follow.
                out.append((now, 0, "✘ %s · did not finish" % self.name(running),
                            "result", {"parts": ("✘", self.name(running),
                                                 " · did not finish"),
                                       "children": self.children(running)}))
            unfinished += [os.path.basename(p)[:-6] for p, ended in sorted(lane.ended.items())
                           if not ended]
        self.lane = self.lanes[0]
        self.done = True
        # Planned suites that reported no test: their process never got to one (Q27).
        empty = [(s, at) for s, at in self.planned_suites if s not in self.reported]
        unfinished = [s for s in unfinished if s not in {s for s, _ in empty}]
        for suite, at in empty:
            what = "%s: %s ran no tests" % (at, suite)
            why = self.why_empty(suite)
            out.append((now, 0, "✘ %s — %s" % (what, why), "result", {
                "parts": ("✘", what, ""), "children": [("", why, [])]}))
        if self.parallel:
            # One line for the whole run, as a serial run's test process prints it.
            failed_any = any(r[2] == "failed" for r in self.results) or unfinished or empty
            ran = len(self.started) + sum(self.skipped.values())
            suites = len({test.split("/", 1)[0] for test in self.started}
                         | {r[0].split("/", 1)[0] for r in self.results})
            out.append((now, 0, "Test run with %d test%s in %d suite%s %s after %.3f seconds." % (
                ran, "" if ran == 1 else "s", suites, "" if suites == 1 else "s",
                "failed" if failed_any else "passed", now - (self.run_started or now)), "result"))
            for suite in unfinished:
                out.append((now, 0, "lab: %s ended without its summary" % suite, "result"))
        elif self.summary is None:
            out.append((now, 0, "lab: the test run ended without its summary", "result"))
        counts = {}
        for _, _, status, _ in self.results:
            counts[status] = counts.get(status, 0) + 1
        ran = [r for r in self.results if r[2] != "skipped"]
        took = span(now - self.run_started) if self.run_started else "?"
        out.append((now, 0, "lab: %d tests · %s · %s" % (len(self.results), " · ".join(
            "%d %s%s" % (counts[s], s, "s" if s == "known issue" and counts[s] > 1 else "")
            for s in ("passed", "known issue", "failed", "skipped")
            if counts.get(s)) or "none ran", took), "result"))
        if self.skipped:
            out.append((now, 0, "lab: skipped\n" + "\n".join(
                "%7d  %s" % (n, reason or "not in this run's tiers") for reason, n in sorted(
                    self.skipped.items(), key=lambda item: -item[1])), "result"))
        slowest = sorted(ran, key=lambda r: -r[3])[:5]
        if slowest:
            out.append((now, 0, "lab: slowest\n" + "\n".join(
                "%7s  %s" % (span(r[3]), r[1]) for r in slowest), "result"))
        failed = [r for r in ran if r[2] == "failed"]
        if failed:
            out.append((now, 0, "lab: failed\n" + "\n".join(
                "%s (%s)" % (r[1], ", ".join(
                    at for known, at in self.issues.get(r[0], []) if not known) or "?")
                for r in failed), "result"))
        # Each warning once more (a retry the harness rode over, a kept start failure): one that
        # starts to recur reads as what it may be, a product bug, at the end of a long run.
        warned = ["%s — %s: %s" % (self.name(test_id), at, fit(text.split("\n", 1)[0], 160))
                  for test_id, items in self.details.items()
                  for glyph, at, text, _ in items if glyph == "!"]
        if warned:
            out.append((now, 0, "lab: warnings\n" + "\n".join(warned), "result"))
        self.emit(out, now)
        with open(os.path.join(self.root, "report", "test-times.tsv"), "w") as f:
            f.write("seconds\tstatus\ttest\n")
            for _, name, status, seconds in sorted(self.results, key=lambda r: -r[3]):
                f.write("%.1f\t%s\t%s\n" % (seconds, status, name))
        if empty:
            return 3
        if self.parallel:
            return 2 if unfinished else 0
        return 0 if self.summary is not None else 2


def follow(root, level, stop, stall=60.0, interval=0.5, out=None, tty=None, size=None,
           shards=(), planned=None, suites=None):
    out = out or sys.stdout
    if tty is None:
        tty = out.isatty() and os.environ.get("TERM", "dumb") != "dumb"
    os.makedirs(os.path.join(root, "report"), exist_ok=True)
    with open(os.path.join(root, "report", "progress.log"), "a", buffering=1) as log:
        follower = Follower([root] + list(shards), level, out, log, stall, tty, size, planned,
                            suites)
        try:
            while True:
                done = stop is not None and os.path.exists(stop)
                follower.tick()
                if done:
                    follower.tick()
                    return follower.finish()
                time.sleep(interval)
        finally:
            follower.close()


# --- self-check ----------------------------------------------------------------------------

class Terminal:
    """Enough of a terminal to replay the live block's output: text, \\n, \\r, CSI n A, CSI J,
    and the codes it ignores (colours, synchronized updates)."""

    def __init__(self):
        self.rows, self.row = [""], 0

    def feed(self, data):
        i = 0
        while i < len(data):
            match = re.match(r"\x1b\[(\??)(\d*)([A-Za-z])", data[i:])
            if match:
                n = int(match.group(2) or 1)
                if match.group(3) == "A":
                    self.row = max(0, self.row - n)
                elif match.group(3) == "J":
                    del self.rows[self.row + 1:]
                    self.rows[self.row] = ""
                i += match.end()
                continue
            c = data[i]
            if c == "\n":
                self.row += 1
                if self.row == len(self.rows):
                    self.rows.append("")
            elif c != "\r":
                self.rows[self.row] += c
            i += 1
        return [r for r in self.rows if r]


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

    def stamp(epoch):
        return datetime.fromtimestamp(epoch).astimezone().strftime("%Y-%m-%d %H:%M:%S.%f%z")

    def run_dir(root, t0):
        r1 = "Mod.Suite/one()/File.swift:10:3"
        r2 = "Mod.Suite/two()/File.swift:20:3"
        r3 = "Mod.Suite/three()/File.swift:30:3"
        issue = {"isKnown": False, "sourceLocation": {"fileID": "Mod/File.swift", "line": 42}}
        known = {"isKnown": True, "sourceLocation": {"fileID": "Mod/File.swift", "line": 7}}
        write(root + "/report/events.jsonl", [
            test("R1: the guest answers on its console", "one()"),
            test("E7: a known one stays known", "two()", 20),
            test("a test without an id (TB14)", "three()", 30),
            event("runStarted", t0, messages=[("default", "Test run started.")]),
            event("testStarted", t0 + 1, r1),
            event("issueRecorded", t0 + 2, r1, [("fail", "Expectation failed: 1 == 2\nsecond\n")],
                  issue=issue),
            event("testEnded", t0 + 70, r1, [("fail", "failed")]),
            event("testStarted", t0 + 71, r2),
            event("issueRecorded", t0 + 72, r2, [("pass", "Known issue: E7: a known one")],
                  issue=known),
            event("testSkipped", t0 + 73, r3,
                  [("skip", 'Test "a test without an id" skipped: "no image"')]),
            event("testSkipped", t0 + 73, "Mod.Other", [("skip", 'Suite "Other" skipped.')]),
            event("testEnded", t0 + 75, r2, [("pass", "passed")]),
            event("runEnded", t0 + 77, messages=[
                ("fail", "Test run with 3 tests in 1 suite failed after 77 seconds.")]),
        ])
        write(root + "/pids/agent-03.pid", ["4242"])
        write(root + "/logs/unified.ndjson", [
            {"timestamp": stamp(t0 + 5), "processImagePath": "/x/MachmanAgent",
             "processID": 4242, "eventMessage": "[log] serving machman.sock"},
            {"timestamp": stamp(t0 + 5), "processImagePath": "/x/MachmanVMHost",
             "processID": 4243, "eventMessage": "[warning] gone already"},
            {"timestamp": stamp(t0 + 6), "processImagePath": "/x/swiftpm-testing-helper",
             "processID": 1, "eventMessage": "[log] lab: step ▸ waiting for a login — 5 s"},
            "{not json",
        ])
        os.makedirs(root + "/transcripts")
        with open(root + "/transcripts/01-lab-debian-hvc0-try2.log", "wb") as f:
            f.write(b"\x1b[1mDebian GNU/Linux 13\x1b[0m\r\nlab-deb login: ")

    t0 = time.time() - 300
    with tempfile.TemporaryDirectory() as root:
        run_dir(root, t0)
        open(root + "/stop-now", "w").close()
        buf = io.StringIO()
        status = follow(root, 2, root + "/stop-now", interval=0.05, out=buf, tty=False)
        text = buf.getvalue()
        check("plain: a test's start reads its index, the plan's size and what it does",
              "▶ 1/3 the guest answers on its console" in text)
        check("no test line shows the id its name starts with",
              "R1" not in text and "E7" not in text)
        check("a failed test reads ✘ with what it does and its duration",
              "✘ 1/3 the guest answers on its console · 1m09s" in text)
        check("an issue reads its file:line and message, its other lines indented",
              "✘ File.swift:42: Expectation failed: 1 == 2\n" + " " * 13 + "second\n" in text)
        check("a skip shrinks the plan's size; a known issue passes with a note",
              "▶ 2/3 a known one stays known" in text
              and "✔ 2/2 a known one stays known · 4 s · known issue" in text
              and "~ File.swift:7:" in text)
        check("a skip reads its reason (level 1)",
              "– skipped: a test without an id — \"no image\"" in text)
        check("the run's summary line is kept verbatim (igate greps it)",
              "Test run with 3 tests in 1 suite failed" in text)
        check("a suite's skip is no test; the summary counts and names the failure",
              "lab: 3 tests · 1 known issue · 1 failed · 1 skipped · " in text
              and "lab: failed\n" + " " * 13 + "the guest answers on its console (File.swift:42)"
              in text)
        check("skips are counted by reason", 'lab: skipped\n' + " " * 13 + '      1  "no image"'
              in text)
        check("an id tag a name ends with is left out", "(TB14)" not in text)
        check("a known issue's card id is left out", "Known issue: a known one" in text)
        check("an agent line carries its scope, a vmhost line its VM or pid",
              "agent 03       serving machman.sock" in text
              and "vmhost 4243    warning: gone already" in text)
        check("a narrated wait reads as a step", "step ▸ waiting for a login — 5 s" in text)
        check("a console line reads its VM and console; escapes, CRs and the retry go",
              "[lab-debian hvc0] Debian GNU/Linux 13" in text
              and "[lab-debian hvc0] lab-deb login:" in text)
        check("a malformed log line is skipped", "not json" not in text)
        check("the run's summary came: exit 0", status == 0)
        with open(root + "/report/progress.log") as f:
            check("progress.log keeps the level-2 stream", "[lab-debian hvc0]" in f.read())
        with open(root + "/report/test-times.tsv") as f:
            rows = f.read().splitlines()
        check("test-times.tsv lists the slowest first, by what each test does",
              rows[0] == "seconds\tstatus\ttest"
              and rows[1] == "69.0\tfailed\tthe guest answers on its console")

    for name, title in [("th-01-th-vzfb-ttyV-9", "th-vzfb ttyV"),
                        ("02-lab-vzfreebsd-ttyV0.0", "lab-vzfreebsd ttyV0.0"),
                        ("qemu-q-freebsd15-serial", "q-freebsd15 serial"),
                        ("05-tg-copy-hvc0-1a2b3c4d", "tg-copy hvc0")]:
        check("console title of %s reads %r" % (name, title), console_title(name) == title)

    with tempfile.TemporaryDirectory() as root:
        now = time.time()
        write(root + "/report/events.jsonl", [
            test("R1: the guest answers on its console", "one()"),
            event("runStarted", now - 120),
            event("testStarted", now - 100, "Mod.Suite/one()/File.swift:10:3"),
        ])
        write(root + "/logs/unified.ndjson", [
            {"timestamp": stamp(now - 1), "processImagePath": "/x/swiftpm-testing-helper",
             "processID": 1,
             "eventMessage": "[log] lab: step … deb hvc0: waiting ≤3m for a login — 45 s"}])
        quiet = io.StringIO()
        stop = root + "/stop"
        timer = threading.Timer(0.6, lambda: open(stop, "w").close())
        timer.start()
        status = follow(root, 0, stop, stall=0.2, interval=0.05, out=quiet, tty=False)
        timer.join()
        text = quiet.getvalue()
        check("level 0 leaves the lab log out", "  step " not in text)
        check("a quiet run gets a stall line naming the test and its step",
              "… 1/1 the guest answers on its console · running" in text
              and "step … deb hvc0: waiting ≤3m for a login" in text)
        check("a run that never summarized says so and exits 2",
              "ended without its summary" in text and status == 2)
        check("the test it died in reads did not finish",
              "✘ the guest answers on its console · did not finish" in text)

    # The terminal: the live block while a test runs, its collapse when the test ends.
    with tempfile.TemporaryDirectory() as root:
        now = time.time()
        r1 = "Mod.Suite/one()/File.swift:10:3"
        write(root + "/report/events.jsonl", [
            test("R1: the guest answers on its console", "one()"),
            event("runStarted", now - 30), event("testStarted", now - 20, r1)])
        os.makedirs(root + "/transcripts")
        with open(root + "/transcripts/01-lab-debian-hvc0.log", "w") as f:
            f.write("".join("boot line %d\n" % i for i in range(30)))
        write(root + "/logs/unified.ndjson", [
            {"timestamp": stamp(now - 25), "processImagePath": "/x/MachmanAgent",
             "processID": 9, "eventMessage": "[log] the last test's teardown"}])
        screen = io.StringIO()
        log = io.StringIO()
        follower = Follower(root, 2, screen, log, tty=True, size=(80, 30))
        follower.tick()
        check("colours wrap only the lines that have one",
              "None" not in screen.getvalue() and "\x1b[1m▶" in screen.getvalue())
        follower.screen.colour = False
        shown = Terminal().feed(screen.getvalue())
        live = shown[next(i for i, l in enumerate(shown) if l.startswith("▶")):]
        timed = re.compile(r"^  \d\d:\d\d:\d\d \[lab-debian hvc0\] boot line (\d+)$")
        check("a running test's block: its header with its elapsed time at the right edge, then "
              "its output",
              re.match(r"▶ 1/1 the guest answers on its console +2\d s$", live[0])
              and len(live[0]) == 79 and timed.match(live[1])
              and timed.match(live[-1]).group(1) == "29" and len(live) == 11)
        check("output past the window: its first two lines, how many are left out, the newest",
              timed.match(live[1]).group(1) == "0" and timed.match(live[2]).group(1) == "1"
              and live[3] == "  ⋯ 21 more lines ⋯" and timed.match(live[4]).group(1) == "23")
        check("a line from before the test started stays out of its block",
              not any("teardown" in l for l in live))
        stale = Follower(root, 2, io.StringIO(), io.StringIO(), tty=True, size=(80, 30))
        stale.tick()
        # As if the test began 2 s after its console opened, and the line came after that.
        born = os.stat(root + "/transcripts/01-lab-debian-hvc0.log").st_birthtime
        time.sleep(max(0.0, born + 2.2 - time.time()))
        stale.started[r1] = (1, born + 2)
        stale.window = Window()
        with open(root + "/transcripts/01-lab-debian-hvc0.log", "a") as f:
            f.write("a late line\n")
        stale.tick()
        check("a console opened before the running test began stays out of its window",
              stale.window.count == 0)
        check("block lines are cut to the terminal's width", all(len(l) <= 79 for l in live))
        write(root + "/report/events.jsonl", [
            event("testEnded", now - 1, r1, [("pass", "passed")]),
            event("runEnded", now, messages=[("pass", "Test run with 1 test passed.")])])
        follower.tick()
        follower.finish()
        shown = Terminal().feed(screen.getvalue())
        check("when the test ends its block collapses into its result line",
              not any("boot line" in l for l in shown)
              and any(re.match(r"\d\d:\d\d:\d\d ✔ 1/1 the guest answers on its console +19 s$",
                               l) for l in shown))
        check("the output it showed stays in progress.log", "boot line 29" in log.getvalue())
        check("the cursor is hidden while the block is up and shown again after it",
              screen.getvalue().find("\x1b[?25l") < screen.getvalue().rfind("\x1b[?25h")
              and screen.getvalue().count("\x1b[?25l") == 1 and follower.screen.drawn == 0)

    # The terminal: a fixed-height block, results cut to the width, a failure's child lines.
    with tempfile.TemporaryDirectory() as root:
        now = time.time()
        long_name = "R7: " + "a test whose name runs on and on " * 4 + "until it ends"
        r7, r8 = "Mod.Suite/seven()/File.swift:70:3", "Mod.Suite/eight()/File.swift:80:3"
        issue = {"isKnown": False, "sourceLocation": {"fileID": "Mod/File.swift", "line": 71}}
        write(root + "/report/events.jsonl", [
            test(long_name, "seven()", 70), test("R8: a quiet test", "eight()", 80),
            event("runStarted", now - 60), event("testStarted", now - 50, r7),
            event("issueRecorded", now - 45, r7,
                  [("fail", "Expectation failed: a == b\n" + "".join(
                      "detail %d\n" % i for i in range(1, 9)))], issue=issue)])
        os.makedirs(root + "/transcripts")
        with open(root + "/transcripts/01-lab-debian-hvc0.log", "w") as f:
            f.write("one\ntwo\nthree\n")
        screen = io.StringIO()
        follower = Follower(root, 1, screen, io.StringIO(), tty=True, size=(80, 30))
        follower.screen.colour = False
        follower.tick()
        heights = [follower.screen.drawn]
        shown = Terminal().feed(screen.getvalue())
        check("a failure's issue isn't printed while its test runs",
              not any("Expectation failed" in l for l in shown))
        write(root + "/report/events.jsonl", [
            event("testEnded", now - 40, r7, [("fail", "failed")])])
        follower.tick()
        heights.append(follower.screen.drawn)
        write(root + "/report/events.jsonl", [event("testStarted", now - 30, r8)])
        follower.tick()
        heights.append(follower.screen.drawn)
        check("the block keeps its height while tests run, between them and with little output",
              heights == [11, 11, 11])
        shown = Terminal().feed(screen.getvalue())
        result = next(i for i, l in enumerate(shown) if l[9:].startswith("✘ 1/2 "))
        check("a long result line is cut to the width, its duration at the right edge",
              len(shown[result]) == 79 and "…" in shown[result]
              and re.match(r"\d\d:\d\d:\d\d ✘ 1/2 a test .*… +10 s$", shown[result]))
        check("a failure's issue hangs under its result: first two lines, a count, last five",
              shown[result + 1] == " " * 9 + "└─ ✘ File.swift:71: Expectation failed: a == b"
              and shown[result + 2] == " " * 14 + "detail 1"
              and shown[result + 3] == " " * 14 + "⋯ 2 more lines in report/progress.log ⋯"
              and shown[result + 4] == " " * 14 + "detail 4"
              and shown[result + 8] == " " * 14 + "detail 8")
        known = {"isKnown": True, "sourceLocation": {"fileID": "Mod/File.swift", "line": 81}}
        write(root + "/report/events.jsonl", [
            event("issueRecorded", now - 25, r8, [("passWithKnownIssue", "Expectation failed: x"),
                                                  ("details", "E9: the override never boots")],
                  issue=known),
            event("issueRecorded", now - 24, r8, [("warning", "a warning")],
                  issue={"isKnown": False, "sourceLocation": {"fileID": "F.swift", "line": 3}}),
            event("testEnded", now - 20, r8, [("pass", "passed")])])
        follower.tick()
        shown = Terminal().feed(screen.getvalue())
        result = next(i for i, l in enumerate(shown) if l[9:].startswith("✔ 2/2 "))
        check("a known issue hangs under its result by its title, the last child with └─",
              re.match(r"\d\d:\d\d:\d\d ✔ 2/2 a quiet test · known issue +10 s$",
                       shown[result])
              and shown[result + 1] == " " * 9 + "├─ ~ known issue: the override never boots"
              and shown[result + 2] == " " * 9 + "└─ ! F.swift:3: a warning")
        follower.screen.colour = True
        row = follower.rows(now, "", {"parts": ("✔ 2/2", "a quiet test", " · 10 s"),
                                      "note": " · known issue",
                                      "children": [("~", "known issue: it never boots", [])]})
        drawn = follower.screen.render(row[0], 79)
        child = follower.screen.render(row[1], 79)
        check("only the mark and index are coloured; the time and duration dim, the note yellow",
              drawn.startswith("\x1b[2m%s \x1b[0m\x1b[32m✔ 2/2\x1b[0m a quiet test"
                               "\x1b[33m · known issue\x1b[0m" % clock(now))
              and drawn.endswith("\x1b[2m10 s\x1b[0m"))
        check("a note is dim but for its glyph and what it starts with",
              child == " " * 9 + "\x1b[2m└─ \x1b[0m\x1b[33m~\x1b[0m \x1b[33mknown issue:"
              "\x1b[0m\x1b[2m it never boots\x1b[0m")
        check("a window that fits shows all its lines, padded",
              elide(["a", "b", "c"], 10) == ["a", "b", "c"]
              and Window().lines(10) == [])
        quiet = Follower(root, 0, io.StringIO(), io.StringIO(), tty=True, size=(80, 30))
        quiet.tick()
        check("level 0's block is the header and one step line", quiet.screen.drawn == 2)
        quiet.close()

    # A parallel run: two shards, a stream per suite, one suite's process never finishing.
    with tempfile.TemporaryDirectory() as base:
        now = time.time()
        a, b = base + "/mml.aaaa", base + "/mml.bbbb"
        a1, b1 = "Mod.Suite/a1()/File.swift:10:3", "Mod.Suite/b1()/File.swift:20:3"
        write(a + "/report/events/LongTests.jsonl", [
            test("A1: the long one", "a1()"), event("runStarted", now - 40),
            event("testStarted", now - 39, a1),
            event("testEnded", now - 9, a1, [("pass", "ok")]),
            event("runEnded", now - 8, messages=[("pass", "Test run with 1 test passed.")])])
        for root, which in ((a, "LongTests"), (b, "ShortTests")):
            write(root + "/logs/unified.ndjson", [
                {"timestamp": stamp(now - 20), "processImagePath": "/x/MachmanAgent",
                 "processID": 7, "eventMessage": "[log] serving for " + which}])
        write(b + "/report/events/ShortTests.jsonl", [
            test("B1: the short one", "b1()", 20), event("runStarted", now - 30),
            event("testStarted", now - 29, b1)])
        tick = Follower([a, b], 1, io.StringIO(), io.StringIO(), tty=True, size=(80, 30),
                        planned=3)
        tick.screen.colour = False
        tick.tick()
        shown = Terminal().feed(tick.out.getvalue())
        check("a parallel run's block: one per shard, fixed height (header and 6 lines each)",
              tick.screen.drawn == 14 and sum(1 for l in shown if l.startswith("▶ ")) == 1
              and any(l.startswith("▶ 2/3 the short one") for l in shown)
              and any(l.startswith("· idle") for l in shown))
        open(base + "/stop", "w").close()
        plain = io.StringIO()
        status = follow(a, 1, base + "/stop", interval=0.05, out=plain, tty=False,
                        shards=[b], planned=3)
        text = plain.getvalue()
        check("a parallel run announces the plan and its shards once",
              text.count("lab: 3 tests planned · 2 shards") == 1)
        check("a parallel run's log lines name their shard",
              "1│agent" in text and "2│agent" in text)
        check("a suite's own run summary is no result line", "Test run with 1 test" not in text)
        check("one summary line for the whole run",
              "Test run with 2 tests in 1 suite failed after" in text)
        check("a suite whose process never finished is named, the test it ran did not finish",
              "lab: ShortTests ended without its summary" in text
              and "✘ the short one · did not finish" in text and status == 2)

    # A planned suite that reported nothing: its process never got to a test (Q27).
    with tempfile.TemporaryDirectory() as base:
        now = time.time()
        a, b = base + "/mml.aaaa", base + "/mml.bbbb"
        a1 = "MachmanLabTests.LongTests/a1()/Long.swift:10:3"
        write(a + "/report/events/LongTests.jsonl", [
            {"kind": "test", "version": 0, "payload": {
                "kind": "function", "id": a1, "name": "a1()", "displayName": "A1: the long one"}},
            event("runStarted", now - 20), event("testStarted", now - 19, a1),
            event("testEnded", now - 9, a1, [("pass", "ok")]),
            event("runEnded", now - 8, messages=[("pass", "Test run with 1 test passed.")])])
        write(b + "/report/runs/GoneTests.log", [
            "Another instance of SwiftPM is already running, but this will be ignored since "
            "`--ignore-lock` has been passederror: unable to attach DB: error: accessing build "
            "database \"x/build.db\": database is locked",
            "error: no tests found; create a target in the 'Tests' directory"])
        os.makedirs(b + "/report/events", exist_ok=True)
        write(a + "/report/suite-runs.tsv", [
            "LongTests\t0\t0\t11", "GoneTests\t1\t1\t6", "QuietTests\t1\t0\t2"])
        write(base + "/suites", ["LongTests\tLong.swift:3\t1", "GoneTests\tGone.swift:12\t2",
                                 "QuietTests\tQuiet.swift:7\t1"])
        open(base + "/stop", "w").close()
        plain = io.StringIO()
        status = follow(a, 0, base + "/stop", interval=0.05, out=plain, tty=False, shards=[b],
                        planned=4, suites=base + "/suites")
        text = plain.getvalue()
        line = next((l for l in text.splitlines() if "GoneTests ran no tests" in l), "")
        check("a planned suite with no result is a ✘ line at its place, saying why (Q27)",
              "✘ Gone.swift:12: GoneTests ran no tests — test exit 1: error: unable to "
              "attach DB" in line)
        check("failcheck's issue pattern reads that line as Gone.swift:12 (Q27)", re.findall(
            r"(?:recorded an issue at |[✘!] )([A-Za-z0-9_+]+\.swift):(\d+)", line)
            == [("Gone.swift", "12")])
        check("a run with a suite that reported nothing fails (Q27)",
              "Test run with 1 test in 1 suite failed after" in text
              and "LongTests ran no tests" not in text)
        check("a suite whose process exited 0 without a result is named, and progress exits 3 "
              "(Q27)", "✘ Quiet.swift:7: QuietTests ran no tests — test exit 0" in text
              and status == 3)

    # One row two suites run (one per guest OS), and a parameterized test failing with one
    # of its arguments: each line says which.
    with tempfile.TemporaryDirectory() as root:
        t0 = time.time() - 60
        deb, alp = "Mod.DebRows/s1()/Rows.swift:10:3", "Mod.AlpRows/s1()/Rows.swift:20:3"
        g9 = "Mod.Mounts/mounts(kind:)/Mounts.swift:30:3"
        boot = {"isKnown": False, "sourceLocation": {"fileID": "Mod/Mounts.swift", "line": 83}}

        def record(kind, test_id, display):
            return {"kind": "test", "version": 0, "payload": {
                "kind": kind, "id": test_id, "name": test_id, "displayName": display}}

        write(root + "/report/events.jsonl", [
            record("suite", "Mod.DebRows", "L3 Guest Setup — Debian read-only rows"),
            record("function", deb, "S1: install.sh --help exits 0"),
            record("suite", "Mod.AlpRows", "L3 Guest Setup — Alpine read-only rows"),
            record("function", alp, "S1: install.sh --help exits 0"),
            record("suite", "Mod.Mounts", "L3 Guest Setup — automounts"),
            record("function", g9, "G9: automounts mount at boot"),
            event("runStarted", t0, messages=[("default", "Test run started.")]),
            event("testStarted", t0 + 1, deb), event("testEnded", t0 + 2, deb, [("pass", "ok")]),
            event("testStarted", t0 + 3, alp), event("testEnded", t0 + 4, alp, [("pass", "ok")]),
            event("testStarted", t0 + 5, g9),
            event("issueRecorded", t0 + 6, g9, [("fail", "Expectation failed: booted")],
                  issue=boot, _testCase={"displayName": "debian", "id": "case"}),
            event("testEnded", t0 + 7, g9, [("fail", "failed")]),
            event("runEnded", t0 + 8, messages=[
                ("fail", "Test run with 3 tests in 3 suites failed after 8 seconds.")]),
        ])
        open(root + "/stop-now", "w").close()
        buf = io.StringIO()
        follow(root, 0, root + "/stop-now", interval=0.05, out=buf, tty=False)
        text = buf.getvalue()
        check("a row two suites run reads which suite it is",
              "✔ 1/3 install.sh --help exits 0 (Debian read-only rows)" in text
              and "✔ 2/3 install.sh --help exits 0 (Alpine read-only rows)" in text)
        check("a name no other test has stays bare",
              "✘ 3/3 automounts mount at boot · " in text and "(automounts)" not in text)
        check("a parameterized test's issue and its failed line name the argument",
              "Mounts.swift:83 [debian]: Expectation failed: booted" in text
              and "automounts mount at boot (Mounts.swift:83 [debian])" in text)

    # Event stream 6.3 (Q42): a warning (a retry the harness rode over) arrives as an issue of
    # severity "warning"; an issue recorded with only a comment is Swift Testing's "Issue
    # recorded" followed by the comment.
    with tempfile.TemporaryDirectory() as root:
        t0 = time.time() - 60
        w1, c1 = "Mod.Suite/warns()/File.swift:10:3", "Mod.Suite/fails()/File.swift:20:3"

        def issue(line, severity):
            return {"isKnown": False, "severity": severity, "isFailure": severity == "error",
                    "sourceLocation": {"fileID": "Mod/Retry.swift", "line": line}}

        write(root + "/report/events.jsonl", [
            test("R1: a retry warns", "warns()"), test("R2: a comment fails", "fails()", 20),
            event("runStarted", t0),
            event("testStarted", t0 + 1, w1),
            event("issueRecorded", t0 + 2, w1, [("warning", "Issue recorded"),
                                                ("details", "retried once: a stop settled")],
                  issue=issue(12, "warning")),
            event("testEnded", t0 + 3, w1, [("pass", "passed with 1 warning")]),
            event("testStarted", t0 + 4, c1),
            event("issueRecorded", t0 + 5, c1, [("fail", "Issue recorded"),
                                                ("details", "no console")],
                  issue=issue(22, "error")),
            event("testEnded", t0 + 6, c1, [("fail", "failed")]),
            event("runEnded", t0 + 7, messages=[
                ("fail", "Test run with 2 tests in 1 suite failed after 7 seconds with 2 issues "
                 "(including 1 warning).")]),
        ])
        open(root + "/stop-now", "w").close()
        buf = io.StringIO()
        follow(root, 0, root + "/stop-now", interval=0.05, out=buf, tty=False)
        text = buf.getvalue()
        check("Q42: an issue recorded with only a comment reads that comment, a warning never "
              "failing its test",
              "! Retry.swift:12: retried once: a stop settled\n" in text
              and "✔ 1/2 a retry warns · " in text
              and "✘ Retry.swift:22: no console\n" in text and "Issue recorded" not in text)
        check("Q42: a run's warnings are listed once more at its end",
              "lab: warnings\n" + " " * 13 + "a retry warns — Retry.swift:12: retried once: a stop "
              "settled\n" in text and text.count("Retry.swift:12") == 2)

    print("progress.py self-check: %s" % ("FAIL (%d)" % len(fails) if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    args = {"--level": "0", "--stall": "60"}
    plain, shards = False, []
    i = 0
    while i < len(argv):
        if argv[i] == "--self-check":
            return self_check()
        if argv[i] == "--plain":
            plain = True
            i += 1
            continue
        if argv[i] == "--shard" and i + 1 < len(argv):
            shards.append(argv[i + 1])
            i += 2
            continue
        if argv[i] in ("--run", "--level", "--stop", "--stall", "--planned", "--suites") \
                and i + 1 < len(argv):
            args[argv[i]] = argv[i + 1]
            i += 2
            continue
        sys.stderr.write(__doc__)
        return 64
    if "--run" not in args:
        sys.stderr.write(__doc__)
        return 64
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        planned = int(args["--planned"]) if "--planned" in args else None
        return follow(args["--run"], int(args["--level"]), args.get("--stop"),
                      stall=float(args["--stall"]), tty=False if plain else None,
                      shards=shards, planned=planned, suites=args.get("--suites"))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
