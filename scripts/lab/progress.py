#!/usr/bin/env python3
"""lab.sh's live progress: a run's Swift Testing event stream, its lab log and its console
transcripts, shown while the run goes. Tests are named by what they do: the "<id>: " their
names start with is left out.

  progress.py --run ROOT [--level 0|1|2] [--plain] [--stop FILE] [--stall SECONDS]
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

Inputs (lab.sh's run dir ROOT): report/events.jsonl (swift test --event-stream-output-path,
version 0), logs/unified.ndjson (log stream --style ndjson), transcripts/*.log, pids/*.pid.
Writes report/progress.log (level 2, plain, whatever --level is) and report/test-times.tsv.
Stops when FILE exists and the inputs are drained; exit 0 when the run's summary came, 2 when
it never did (the test process crashed or was killed).
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
# terminal); "stall" is plain only. Extras, for the terminal: "parts" (prefix, name, suffix:
# the name is what gets cut to fit), "children" (indented lines under it), "test".


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

    def add(self, line):
        if len(self.head) < 2:
            self.head.append(line)
        self.tail.append(line)
        self.count += 1

    def lines(self, height):
        if self.count <= height:
            return list(self.tail)[-self.count:] if self.count else []
        newest = list(self.tail)[-(height - 3):]
        return self.head + [gap(self.count - 2 - len(newest))] + newest


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

    def update(self, above, block):
        """`above` and `block` are (colour code, text) rows, each cut to the width."""
        if not above and block == self.last:
            return
        width = self.dimensions()[0] - 1
        parts = ["\x1b[?2026h"]  # synchronized update, where the terminal knows it
        if block and not self.hidden:
            parts.append("\x1b[?25l")
            self.hidden = True
        if self.drawn:
            parts.append("\r\x1b[%dA\x1b[J" % self.drawn)
        parts.extend(self.paint(code, fit(text, width)) + "\n" for code, text in above + block)
        if not block and self.hidden:
            parts.append("\x1b[?25h")
            self.hidden = False
        parts.append("\x1b[?2026l")
        self.out.write("".join(parts))
        self.out.flush()
        self.drawn, self.last = len(block), block


class Follower:
    def __init__(self, root, level, out, log, stall=60.0, tty=False, size=None):
        self.root, self.level, self.out, self.log, self.stall = root, level, out, log, stall
        self.screen = Screen(out, "NO_COLOR" not in os.environ, size) if tty else None
        self.events = Tail(os.path.join(root, "report", "events.jsonl"))
        self.unified = Tail(os.path.join(root, "logs", "unified.ndjson"))
        self.consoles = {}
        self.plan = {}
        self.started = {}            # test id -> (index, start epoch)
        self.skipped = {}            # reason -> count
        self.issues = {}             # test id -> [(known, where)]
        self.details = {}            # test id -> [(glyph, where, text)]
        self.done = False
        self.results = []            # (id, about, status, seconds)
        self.current = None
        self.step = None             # (epoch, text) of the latest narration
        self.console = None          # (title, last line)
        self.window = Window()
        self.pids = {}
        self.summary = None
        self.run_started = None
        self.printed = time.time()

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
                    self.current is None or epoch >= self.started[self.current][1]):
                # (A line older than the running test is the last one's teardown, late.)
                parts = text.strip().split("\n")
                self.window.add("%s %s" % (clock(epoch), parts[0].rstrip()))
                for part in parts[1:]:
                    if part.strip():
                        self.window.add(" " * 9 + part.strip())
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
        return {"✔": "32", "✘": "31", "~": "33", "!": "33", "–": "2"}.get(text.lstrip()[:1])

    def squeeze(self, prefix, parts, reserved=0):
        """prefix + parts' prefix, name and suffix, the name cut so the line fits the width."""
        head, name, tail = parts
        room = self.screen.dimensions()[0] - 1 - reserved - len(prefix + head + tail)
        return prefix + head + fit(name, max(10, room)) + tail

    def rows(self, epoch, text, extras):
        """A result's rows on the terminal: its line, then its child lines."""
        lines = [l.rstrip() for l in text.split("\n")]
        first = "%s %s" % (clock(epoch), lines[0].strip())
        if "parts" in extras:
            first = self.squeeze(clock(epoch) + " ", extras["parts"])
        children = extras.get("children")
        if children is None:
            children = [l.strip() for l in lines[1:] if l.strip()]
        rows = [(self.colour(first[9:]), first)]
        rows.extend((self.colour(c), " " * 11 + c) for c in children)
        return rows

    def children(self, test_id):
        """A test's issues as child lines: a failure's message (8 lines at most: its first
        two, how many are left out, its last five), a known issue's first line."""
        out = []
        for glyph, at, text in self.details.get(test_id, []):
            lines = [l.strip() for l in text.split("\n") if l.strip()] or [""]
            if glyph == "~":
                out.append("%s %s: %s" % (glyph, at, lines[0]))
                continue
            lines[0] = "%s %s: %s" % (glyph, at, lines[0])
            shown = elide(lines, 8, " in report/progress.log")
            out.append(shown[0])
            out.extend("  " + l for l in shown[1:])
        return out

    def block(self, now):
        """The live block, the same height from the first test to the last: the running
        test's header, then its step (level 0) or a window of its latest output (levels 1
        and 2), padded with blank lines."""
        if self.done:
            return []
        height = 1 if self.level == 0 else min(10, max(3, self.screen.dimensions()[1] // 3))
        if self.current is not None:
            index, start = self.started[self.current]
            header = self.squeeze("", ("▶ %s " % self.of(index), about(
                self.display(self.current)), " · %s" % span(now - start)))
        elif self.started:
            header = "▶ between tests"
        else:
            header = "▶ starting the test run"
        body = []
        if self.level == 0:
            if self.current is not None and self.step is not None \
                    and self.step[0] >= self.started[self.current][1] \
                    and not self.step[1].startswith(("✓", "✘")):
                body.append("  " + self.step[1])
        elif self.current is not None:
            body.extend("  " + l for l in self.window.lines(height))
        body += [""] * (height - len(body))
        return [("1", header)] + [("2", b) for b in body]

    # --- the event stream -------------------------------------------------------------------

    def display(self, test_id):
        return self.plan.get(test_id, test_id)

    def of(self, index):
        """"5/184": the index among the planned tests not skipped so far."""
        return "%d/%d" % (index, len(self.plan) - sum(self.skipped.values()))

    def on_record(self, record, out):
        payload = record.get("payload", {})
        if record.get("kind") == "test":
            if payload.get("kind") == "function":
                self.plan[payload["id"]] = payload.get("displayName") or payload.get("name", "")
            return
        kind = payload.get("kind")
        when = payload.get("instant", {}).get("since1970", time.time())
        test_id = payload.get("testID")
        messages = payload.get("messages", [])
        first = messages[0]["text"] if messages else ""
        if kind == "runStarted":
            self.run_started = when
            out.append((when, 0, "lab: %d test%s planned" % (
                len(self.plan), "" if len(self.plan) == 1 else "s"), "result"))
        elif kind == "testStarted" and test_id in self.plan:
            index = len(self.started) + 1
            self.started[test_id] = (index, when)
            self.current = test_id
            self.window = Window()
            out.append((when, 0, "▶ %s %s" % (self.of(index), about(self.display(test_id))),
                        "start"))
        elif kind == "testStarted":
            out.append((when, 1, "· %s" % first, "detail"))
        elif kind == "issueRecorded":
            issue = payload.get("issue", {})
            known = bool(issue.get("isKnown"))
            where = issue.get("sourceLocation", {})
            at = "%s:%s" % (os.path.basename(where.get("fileID", "?")), where.get("line", "?"))
            symbol = messages[0].get("symbol") if messages else ""
            glyph = "~" if known else ("!" if symbol == "warning" else "✘")
            text = CARD.sub("", " ".join(m["text"] for m in messages if m.get("text")))
            if test_id is not None:
                self.issues.setdefault(test_id, []).append((known, at))
                self.details.setdefault(test_id, []).append((glyph, at, text[:2000]))
            out.append((when, 0, "  %s %s: %s" % (glyph, at, text[:2000]), "issue",
                        {"test": test_id}))
        elif kind == "testSkipped" and test_id in self.plan:
            match = SKIPPED.match(first)
            reason = match.group(1) if match and match.group(1) else ""
            self.skipped[reason] = self.skipped.get(reason, 0) + 1
            self.results.append((test_id, about(self.display(test_id)), "skipped", 0.0))
            # A skip with a reason says something (-v); one for a tier not in this run doesn't.
            out.append((when, 1 if reason else 2, "– skipped: %s%s" % (
                about(self.display(test_id)), (" — " + reason) if reason else ""), "result",
                {"parts": ("– skipped: ", about(self.display(test_id)), ""),
                 "children": [reason] if reason else []}))
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
            self.results.append((test_id, about(self.display(test_id)), status, seconds))
            glyph = "✘" if failed else "✔"
            out.append((when, 0, "%s %s %s · %s%s" % (
                glyph, self.of(index), about(self.display(test_id)), span(seconds), note),
                "result", {"parts": ("%s %s " % (glyph, self.of(index)),
                                     about(self.display(test_id)),
                                     " · %s%s" % (span(seconds), note)),
                           "children": self.children(test_id)}))
            if self.current == test_id:
                self.current = None
                self.window = Window()
        elif kind == "testEnded":
            out.append((when, 1, "· %s" % first, "detail"))
        elif kind == "runEnded":
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
        if STEP in message:
            self.step = (when, message.split(STEP, 1)[1])
            out.append((when, 1, "  step %s" % self.step[1], "step"))
            return
        text = re.sub(r"^\[log\] ", "", message)
        text = re.sub(r"^\[([a-z-]+)\] ", r"\1: ", text)
        out.append((when, 1, "  %-14s %s" % (self.who(entry), text[:2000]), "detail"))

    def on_console(self, name, raw, now, out):
        line = ESCAPES.sub(b"", raw).replace(b"\r", b"").decode("utf-8", "replace").rstrip()
        if not line.strip():
            return
        title = console_title(name)
        self.console = (title, line.strip())
        out.append((now, 2, "  [%s] %s" % (title, line), "detail"))

    def stalled(self, now, out):
        if self.screen is not None or self.current is None or now - self.printed < self.stall:
            return
        index, start = self.started[self.current]
        parts = ["… %s %s · running %s" % (
            self.of(index), about(self.display(self.current)), span(now - start))]
        if self.step is not None and self.step[0] >= start:
            parts.append("step " + self.step[1])
        if self.console is not None:
            parts.append("[%s] %s" % (self.console[0], self.console[1][:120]))
        out.append((now, 0, " · ".join(parts), "stall"))

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
            for raw in tail.lines(now):
                self.on_console(os.path.basename(path)[:-4], raw, now, out)
        self.stalled(now, out)
        self.emit(out, now)

    def close(self):
        """Takes the live block off the screen and shows the cursor again (an interrupted run
        leaves no half block)."""
        self.done = True
        if self.screen is not None and (self.screen.drawn or self.screen.hidden):
            self.screen.last = None
            self.screen.update([], [])

    def finish(self):
        now, out = time.time(), []
        for path, tail in sorted(self.consoles.items()):
            if tail.rest:
                self.on_console(os.path.basename(path)[:-4], tail.rest, now, out)
                tail.rest = b""
        running, self.current = self.current, None
        self.done = True
        if running is not None:
            # The test process died in it: its issues never got a result line to follow.
            out.append((now, 0, "✘ %s · did not finish" % about(self.display(running)),
                        "result", {"parts": ("✘ ", about(self.display(running)),
                                             " · did not finish"),
                                   "children": self.children(running)}))
        if self.summary is None:
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
        self.emit(out, now)
        with open(os.path.join(self.root, "report", "test-times.tsv"), "w") as f:
            f.write("seconds\tstatus\ttest\n")
            for _, name, status, seconds in sorted(self.results, key=lambda r: -r[3]):
                f.write("%.1f\t%s\t%s\n" % (seconds, status, name))
        return 0 if self.summary is not None else 2


def follow(root, level, stop, stall=60.0, interval=0.5, out=None, tty=None, size=None):
    out = out or sys.stdout
    if tty is None:
        tty = out.isatty() and os.environ.get("TERM", "dumb") != "dumb"
    os.makedirs(os.path.join(root, "report"), exist_ok=True)
    with open(os.path.join(root, "report", "progress.log"), "a", buffering=1) as log:
        follower = Follower(root, level, out, log, stall, tty, size)
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
        check("a running test's block: its header with elapsed time, then its output",
              live[0].startswith("▶ 1/1 the guest answers on its console · 2")
              and live[1].startswith("  " + clock(now)[:5])
              and live[-1].endswith(" [lab-debian hvc0] boot line 29") and len(live) == 11)
        check("output past the window: its first two lines, how many are left out, the newest",
              live[1].endswith("boot line 0") and live[2].endswith("boot line 1")
              and live[3] == "  ⋯ 21 more lines ⋯" and live[4].endswith("boot line 23"))
        check("a line from before the test started stays out of its block",
              not any("teardown" in l for l in live))
        check("block lines are cut to the terminal's width", all(len(l) <= 79 for l in live))
        write(root + "/report/events.jsonl", [
            event("testEnded", now - 1, r1, [("pass", "passed")]),
            event("runEnded", now, messages=[("pass", "Test run with 1 test passed.")])])
        follower.tick()
        follower.finish()
        shown = Terminal().feed(screen.getvalue())
        check("when the test ends its block collapses into its result line",
              not any("boot line" in l for l in shown)
              and any("✔ 1/1 the guest answers on its console · 19 s" in l for l in shown))
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
        result = next(i for i, l in enumerate(shown) if " ✘ 1/2 " in l)
        check("a long result line is cut to the width and keeps its duration",
              len(shown[result]) <= 79 and "…" in shown[result]
              and shown[result].endswith(" · 10 s"))
        check("a failure's issue follows as child lines: its first two, a count, its last five",
              shown[result + 1] == " " * 11 + "✘ File.swift:71: Expectation failed: a == b"
              and shown[result + 2] == " " * 11 + "  detail 1"
              and shown[result + 3] == " " * 11 + "  ⋯ 2 more lines in report/progress.log ⋯"
              and shown[result + 4] == " " * 11 + "  detail 4"
              and shown[result + 8] == " " * 11 + "  detail 8")
        check("a window that fits shows all its lines, padded",
              elide(["a", "b", "c"], 10) == ["a", "b", "c"]
              and Window().lines(10) == [])
        quiet = Follower(root, 0, io.StringIO(), io.StringIO(), tty=True, size=(80, 30))
        quiet.tick()
        check("level 0's block is the header and one step line", quiet.screen.drawn == 2)
        quiet.close()

    print("progress.py self-check: %s" % ("FAIL (%d)" % len(fails) if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    args = {"--level": "0", "--stall": "60"}
    plain = False
    i = 0
    while i < len(argv):
        if argv[i] == "--self-check":
            return self_check()
        if argv[i] == "--plain":
            plain = True
            i += 1
            continue
        if argv[i] in ("--run", "--level", "--stop", "--stall") and i + 1 < len(argv):
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
        return follow(args["--run"], int(args["--level"]), args.get("--stop"),
                      stall=float(args["--stall"]), tty=False if plain else None)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
