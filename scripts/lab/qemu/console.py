#!/usr/bin/env python3
"""Drive a lab guest's console behind a UNIX socket (QEMU's serial/virtconsole chardevs).

usage:
  console.py SOCK [--transcript F] login --user U [--password P] [--nudge S] --timeout S
  console.py SOCK [--transcript F] run --timeout S -- CMD...
  console.py SOCK [--transcript F] expect REGEX [--nudge S] --timeout S
  console.py SOCK [--transcript F] send TEXT
  console.py SOCK qmp COMMAND [--arguments JSON] --timeout S
  console.py --self-test

login sends nothing until a 'login:' prompt (keys that reach a boot loader interrupt it),
nudges with a newline after --nudge seconds of quiet (the prompt may have been printed before
we connected), answers the password prompt (empty unless --password) and stops at a shell
prompt ending in '# ' or '$ '. run sends one shell line,
  echo "__LAB_BEGIN_$((40+2))_<nonce>"; CMD; echo "__LAB_RC_$((40+2))_<nonce>=$?"
so the tty's echo of the line can never match the markers, prints what CMD printed and exits
with CMD's status. expect waits for REGEX in what arrives. qmp runs one QMP command and prints
its return value as JSON. Everything received is appended raw to --transcript.

Exit codes: the guest command's status (run), 0 (login/expect/send/qmp ok), 1 (refused login,
QMP error), 124 (timeout), 125 (no console: connect failed or the socket closed), 64 (usage).
Standard library only; the lab scripts call it through a resolved python3 (never the
Command Line Tools shim without a developer dir).
"""
import argparse
import json
import os
import re
import secrets
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ANSI = re.compile(rb"\x1b\[[0-9;:?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
	rb"|\x1b[()][A-Za-z0-9]|\x1b[=>78]")
PROMPT = re.compile(rb"(?:^|\n)[^\n]{0,120}[#$] ?$")
LOGIN = re.compile(rb"login: ?$")
PASSWORD = re.compile(rb"[Pp]assword: ?$")


class ConsoleError(Exception):
	def __init__(self, code, message):
		super().__init__(message)
		self.code = code


class Console:
	def __init__(self, path, transcript=None, connect_timeout=10.0):
		self.buf = b""
		self.tf = open(transcript, "ab") if transcript else None
		deadline = time.monotonic() + connect_timeout
		while True:
			self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
			try:
				self.sock.connect(path)
				break
			except OSError as e:
				self.sock.close()
				if time.monotonic() >= deadline:
					raise ConsoleError(125, f"cannot connect to {path}: {e.strerror}")
				time.sleep(0.2)
		self.last_data = time.monotonic()

	def close(self):
		self.sock.close()
		if self.tf:
			self.tf.close()

	def pump(self, seconds):
		"""Read for up to `seconds`; raises on EOF."""
		end = time.monotonic() + seconds
		while True:
			left = end - time.monotonic()
			if left <= 0:
				return
			r, _, _ = select.select([self.sock], [], [], min(left, 0.2))
			if not r:
				continue
			data = self.sock.recv(65536)
			if not data:
				raise ConsoleError(125, "the console closed")
			self.buf += data
			self.last_data = time.monotonic()
			if self.tf:
				self.tf.write(data)
				self.tf.flush()

	def send(self, data):
		self.sock.sendall(data)

	@staticmethod
	def clean(b):
		return ANSI.sub(b"", b).replace(b"\r", b"")

	def login(self, user, password, timeout, nudge):
		deadline = time.monotonic() + timeout
		pos = 0  # prompts count only in what arrived after our last keystroke
		asked = False  # we sent a user name or a nudge: a shell prompt now means logged in
		attempts = 0
		while time.monotonic() < deadline:
			self.pump(0.5)
			tail = self.clean(self.buf[pos:])[-300:]
			if LOGIN.search(tail):
				attempts += 1
				if attempts > 3:
					raise ConsoleError(1, f"login as {user} refused three times")
				self.send(user.encode() + b"\n")
				pos, asked = len(self.buf), True
			elif asked and PASSWORD.search(tail):
				self.send(password.encode() + b"\n")
				pos = len(self.buf)
			elif asked and PROMPT.search(tail):
				return
			elif time.monotonic() - self.last_data > nudge:
				# The prompt (login or shell) went out before we connected: ask for it again.
				self.send(b"\n")
				pos, asked = len(self.buf), True
				self.last_data = time.monotonic()
		raise ConsoleError(124, f"no shell prompt within {timeout:g} s")

	def run(self, cmd, timeout):
		nonce = secrets.token_hex(4)
		self.pump(0.2)
		start = len(self.buf)
		line = (f'echo "__LAB_BEGIN_$((40+2))_{nonce}"; {cmd}; '
			f'echo "__LAB_RC_$((40+2))_{nonce}=$?"')
		self.send(line.encode() + b"\n")
		begin = re.compile(rb"__LAB_BEGIN_42_" + nonce.encode() + rb"\n")
		done = re.compile(rb"__LAB_RC_42_" + nonce.encode() + rb"=(\d+)")
		deadline = time.monotonic() + timeout
		while True:
			text = self.clean(self.buf[start:])
			m = done.search(text)
			if m:
				b = begin.search(text)
				out = text[b.end():m.start()] if b and b.end() <= m.start() else b""
				return int(m.group(1)), out
			left = deadline - time.monotonic()
			if left <= 0:
				raise ConsoleError(124, f"no end marker within {timeout:g} s")
			self.pump(min(left, 0.5))

	def expect(self, pattern, timeout, nudge):
		rx = re.compile(pattern.encode())
		deadline = time.monotonic() + timeout
		while True:
			m = rx.search(self.clean(self.buf))
			if m:
				return m.group(0)
			left = deadline - time.monotonic()
			if left <= 0:
				raise ConsoleError(124, f"'{pattern}' not seen within {timeout:g} s")
			self.pump(min(left, 0.5))
			if nudge and time.monotonic() - self.last_data > nudge:
				self.send(b"\r")
				self.last_data = time.monotonic()


def qmp(path, command, arguments, timeout):
	deadline = time.monotonic() + timeout
	con = Console(path, connect_timeout=min(timeout, 10.0))
	pending = b""

	def message():
		nonlocal pending
		while b"\n" not in pending:
			left = deadline - time.monotonic()
			if left <= 0:
				raise ConsoleError(124, f"QMP {command}: no answer within {timeout:g} s")
			r, _, _ = select.select([con.sock], [], [], min(left, 0.5))
			if r:
				data = con.sock.recv(65536)
				if not data:
					raise ConsoleError(125, "QMP socket closed")
				pending += data
		line, pending = pending.split(b"\n", 1)
		return json.loads(line)

	def reply():
		while True:
			m = message()
			if "return" in m or "error" in m:
				return m

	try:
		message()  # the greeting
		con.send(b'{"execute": "qmp_capabilities"}\n')
		reply()
		req = {"execute": command}
		if arguments:
			req["arguments"] = arguments
		con.send(json.dumps(req).encode() + b"\n")
		m = reply()
	finally:
		con.close()
	if "error" in m:
		raise ConsoleError(1, f"QMP {command}: {m['error'].get('desc', m['error'])}")
	return m["return"]


def main(argv):
	if argv[:1] == ["--self-test"]:
		return self_test()
	p = argparse.ArgumentParser(prog="console.py")
	p.add_argument("sock")
	p.add_argument("--transcript")
	sub = p.add_subparsers(dest="cmd", required=True)
	lg = sub.add_parser("login")
	lg.add_argument("--user", required=True)
	lg.add_argument("--password", default="")
	lg.add_argument("--nudge", type=float, default=30.0)
	lg.add_argument("--timeout", type=float, required=True)
	rn = sub.add_parser("run")
	rn.add_argument("--timeout", type=float, required=True)
	rn.add_argument("command", nargs=argparse.REMAINDER)
	ex = sub.add_parser("expect")
	ex.add_argument("regex")
	ex.add_argument("--nudge", type=float, default=0.0)
	ex.add_argument("--timeout", type=float, required=True)
	sd = sub.add_parser("send")
	sd.add_argument("text")
	qm = sub.add_parser("qmp")
	qm.add_argument("execute")
	qm.add_argument("--arguments", default="")
	qm.add_argument("--timeout", type=float, default=10.0)
	try:
		a = p.parse_args(argv)
	except SystemExit as e:
		return 64 if e.code else 0
	try:
		if a.cmd == "qmp":
			args = json.loads(a.arguments) if a.arguments else None
			print(json.dumps(qmp(a.sock, a.execute, args, a.timeout)))
			return 0
		con = Console(a.sock, a.transcript)
		try:
			if a.cmd == "login":
				con.login(a.user, a.password, a.timeout, a.nudge)
				return 0
			if a.cmd == "run":
				words = a.command[1:] if a.command[:1] == ["--"] else a.command
				if not words:
					print("console.py: run needs a command after --", file=sys.stderr)
					return 64
				rc, out = con.run(" ".join(words), a.timeout)
				sys.stdout.buffer.write(out)
				sys.stdout.flush()
				return rc
			if a.cmd == "expect":
				m = con.expect(a.regex, a.timeout, a.nudge)
				print(m.decode("latin-1"))
				return 0
			if a.cmd == "send":
				con.send(a.text.encode() + b"\n")
				con.pump(0.3)
				return 0
		finally:
			con.close()
	except ConsoleError as e:
		print(f"console.py: {e}", file=sys.stderr)
		return e.code
	return 64


# --- self-test: an in-process getty + login + echoing shell, and a QMP server -------------

RUN_LINE = re.compile(r'^echo "__LAB_BEGIN_\$\(\(40\+2\)\)_(\w+)"; (.*); '
	r'echo "__LAB_RC_\$\(\(40\+2\)\)_(\w+)=\$\?"$')


def fake_getty(conn):
	"""Prints nothing until poked (the prompt went out before the client connected)."""
	f = conn.makefile("rb")
	state = "idle"
	user = ""

	def out(s):
		conn.sendall(s.encode())

	for raw in f:
		line = raw.decode().rstrip("\r\n")
		if state in ("idle", "login"):
			if state == "idle" or not line:
				state = "login"
				out("\r\nFakeBSD/arm64 (lab) (ttyu0)\r\n\r\nlogin: ")
				continue
			user = line
			out(line + "\r\nPassword:")
			state = "password"
		elif state == "password":
			if user == "root" and line == "":
				out("\r\nWelcome.\r\nroot@lab:~ # ")
				state = "shell"
			else:
				out("\r\nLogin incorrect\r\nlogin: ")
				state = "login"
		elif state == "shell":
			out(line + "\r\n")  # the tty's echo
			m = RUN_LINE.match(line)
			if line == "exit":
				return
			if m:
				nonce, cmd = m.group(1), m.group(2)
				out(f"__LAB_BEGIN_42_{nonce}\r\n")
				rc = 0
				if cmd.startswith("echo "):
					out(cmd[5:] + "\r\n")
				elif cmd.startswith("(exit "):
					rc = int(cmd[6:-1])
				elif cmd.startswith("sleep "):
					continue  # never answers: the client's timeout must fire
				out(f"__LAB_RC_42_{nonce}={rc}\r\n")
			out("root@lab:~ # ")


def fake_firmware(conn):
	time.sleep(0.5)
	conn.sendall(b"\x1b[2J\x1b[01;01HUEFI Interactive Shell v2.2\r\nShell> ")
	time.sleep(2)


def fake_qmp(conn):
	f = conn.makefile("rb")
	conn.sendall(b'{"QMP": {"version": {}, "capabilities": []}}\r\n')
	for raw in f:
		req = json.loads(raw)
		if req["execute"] == "qmp_capabilities":
			conn.sendall(b'{"return": {}}\r\n')
		elif req["execute"] == "query-status":
			conn.sendall(b'{"event": "RTC_CHANGE", "data": {}}\r\n')
			conn.sendall(b'{"return": {"status": "running", "running": true}}\r\n')
		else:
			conn.sendall(b'{"error": {"class": "CommandNotFound", "desc": "nope"}}\r\n')


def serve(path, handler):
	srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
	srv.bind(path)
	srv.listen(4)

	def loop():
		while True:
			try:
				conn, _ = srv.accept()
			except OSError:
				return
			threading.Thread(target=lambda c=conn: (handler(c), c.close()), daemon=True).start()

	threading.Thread(target=loop, daemon=True).start()
	return srv


def self_test():
	root = tempfile.mkdtemp(prefix="mml.", dir="/tmp")
	me = os.path.abspath(__file__)
	failures = 0
	servers = []

	def check(name, ok, detail=""):
		nonlocal failures
		print(("ok    " if ok else "FAIL  ") + name + ("" if ok else f": {detail}"))
		failures += 0 if ok else 1

	def cli(*args, timeout=30):
		t0 = time.monotonic()
		r = subprocess.run([sys.executable, me, *args], capture_output=True, timeout=timeout)
		return r.returncode, r.stdout.decode(), r.stderr.decode(), time.monotonic() - t0

	try:
		getty = os.path.join(root, "serial.sock")
		fw = os.path.join(root, "fw.sock")
		qs = os.path.join(root, "qmp.sock")
		servers += [serve(getty, fake_getty), serve(fw, fake_firmware), serve(qs, fake_qmp)]
		tr = os.path.join(root, "serial.transcript")

		rc, out, err, dt = cli(getty, "--transcript", tr, "login", "--user", "root",
			"--nudge", "1", "--timeout", "10")
		check("login (nudged after 1 s of quiet, empty password)", rc == 0, f"rc {rc} {err}")
		rc, out, err, _ = cli(getty, "login", "--user", "eve", "--nudge", "1", "--timeout", "10")
		check("a refused login fails", rc == 1, f"rc {rc} {err}")
		# Every connection is a fresh session on the fake getty: log in and run in one go.
		con = Console(getty, tr)
		con.login("root", "", 10, 1)
		rc0, out0 = con.run("echo hello world", 10)
		rc3, out3 = con.run("(exit 3)", 10)
		con.close()
		check("run prints the output between the markers", rc0 == 0 and out0 == b"hello world\n",
			f"rc {rc0} out {out0!r}")
		check("run returns the guest's status", rc3 == 3 and out3 == b"", f"rc {rc3} {out3!r}")
		con = Console(getty)
		con.login("root", "", 10, 1)
		t0 = time.monotonic()
		try:
			con.run("sleep 999", 2)
			check("run times out", False, "returned")
		except ConsoleError as e:
			dt = time.monotonic() - t0
			check("run times out (124) on a command that never ends", e.code == 124 and dt < 4,
				f"code {e.code} after {dt:.1f} s")
		con.close()
		rc, out, err, _ = cli(fw, "expect", "UEFI|Shell>", "--timeout", "5")
		check("expect matches a firmware banner", rc == 0 and "UEFI" in out, f"rc {rc} {err}")
		rc, out, err, dt = cli(fw, "expect", "never-printed", "--timeout", "1")
		check("expect times out (124)", rc == 124, f"rc {rc} {err}")
		rc, out, err, _ = cli(os.path.join(root, "absent.sock"), "send", "x")
		check("a missing socket is 125", rc == 125, f"rc {rc} {err}")
		rc, out, err, _ = cli(qs, "qmp", "query-status", "--timeout", "5")
		check("qmp skips events and prints the return", rc == 0
			and json.loads(out).get("status") == "running", f"rc {rc} {out} {err}")
		rc, out, err, _ = cli(qs, "qmp", "nonsense", "--timeout", "5")
		check("a QMP error is 1", rc == 1 and "nope" in err, f"rc {rc} {err}")
		with open(tr, "rb") as f:
			t = f.read()
		check("the transcript holds the raw session", b"login: " in t and b"hello world" in t,
			f"{len(t)} bytes")
		rc, out, err, _ = cli(getty, "run", "--timeout", "1")
		check("run without a command is a usage error (64)", rc == 64, f"rc {rc}")
	finally:
		for s in servers:
			s.close()
		shutil.rmtree(root, ignore_errors=True)
	check("the self-test root is gone", not os.path.exists(root), root)
	print("console.py --self-test: " + ("all ok" if failures == 0 else f"{failures} FAILED"))
	return 0 if failures == 0 else 1


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
