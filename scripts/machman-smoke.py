#!/usr/bin/env python3
"""Non-Swift proof for the Machman daemon protocol (stdlib only).

Usage:
  machman-smoke.py [--socket PATH] [info]        hello + list VMs (default)
  machman-smoke.py [--socket PATH] watch         subscribe and stream events (^C to stop)
  machman-smoke.py [--socket PATH] start NAME [--headless] [--safe]
  machman-smoke.py [--socket PATH] stop NAME [--force]
  machman-smoke.py [--socket PATH] call METHOD [PARAMS]
                                                send any request (PARAMS: a JSON object) and
                                                print its result, e.g.
                                                call vm.get '{"name": "Debian"}'

Socket resolution: --socket, else $TMPDIR/<suite>/machman.sock, where <suite> is
$MACHMAN_SUITE_ID, else com.gustaffranzen.Machman (a Debug build is ...Machman.dev).
Sockets live in the runtime dir, NOT in the VM library: sun_path is 104 bytes and the
library is relocatable.
"""

import json
import os
import socket
import sys

DEFAULT_SUITE = "com.gustaffranzen.Machman"


def socket_path(argv):
    if "--socket" in argv:
        i = argv.index("--socket")
        return argv[i + 1], argv[:i] + argv[i + 2:]
    suite = os.environ.get("MACHMAN_SUITE_ID") or DEFAULT_SUITE
    runtime = os.path.join(os.environ.get("TMPDIR", "/tmp"), suite)
    return os.path.join(runtime, "machman.sock"), argv


def start_options(vm, argv):
    """vm.start's options for `vm` (a vm.get answer): the daemon takes explicit options only,
    so every client applies the VM's start policy itself. A plain start follows it whole;
    --headless drops the window and --safe adds a safe run, each keeping the other half
    (StartIntent in MachmanUI, docs/ipc-protocol.md's vm.start)."""
    policy = vm.get("startPolicy") or {}
    return {
        "openWindow": policy.get("windowed", True) and "--headless" not in argv,
        "safe": policy.get("safe", False) or "--safe" in argv,
    }


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def read_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("daemon closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, method, params=None):
        req = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        self.next_id += 1
        if params is not None:
            req["params"] = params
        self.sock.sendall((json.dumps(req) + "\n").encode())
        while True:
            msg = self.read_line()
            if msg.get("id") == req["id"]:
                if "error" in msg:
                    error = msg["error"]
                    # Machman's own code (notFound, invalidState, …) when it sent one.
                    code = (error.get("data") or {}).get("machmanCode") or error["code"]
                    raise RuntimeError(f"{method}: {error['message']} ({code})")
                return msg.get("result")
            # Anything else (events) while waiting: ignore here.

    def events(self):
        self.call("events.subscribe")
        while True:
            msg = self.read_line()
            if msg.get("method") == "event":
                yield msg["params"]


def main(args=None):
    path, argv = socket_path(sys.argv[1:] if args is None else args)
    command = argv[0] if argv else "info"
    params = None
    if command == "call":
        try:
            method = argv[1]
            params = json.loads(argv[2]) if len(argv) > 2 else None
        except (IndexError, json.JSONDecodeError):
            print(__doc__)
            return 2
    try:
        client = Client(path)
    except (FileNotFoundError, ConnectionRefusedError):
        print(f"no daemon at {path} — is MachmanAgent running?", file=sys.stderr)
        return 1

    hello = client.call("machman.hello", {"client": "machman-smoke.py"})
    if command == "info":
        print(f"machman-agent {hello['daemonVersion']} (api v{hello['apiVersion']}) at {path}")
        for vm in client.call("vm.list"):
            window = ", window open" if vm.get("windowOpen") else ""
            print(f"  {vm['name']:20} {vm['state']:9} "
                  f"{vm['cpuCount']} cpu, {vm['memoryBytes'] // 2**30} GiB"
                  f" [{vm['boot']['mode']}]{window}")
    elif command == "watch":
        print("watching events (^C to stop)")
        try:
            for event in client.events():
                print(json.dumps(event))
        except KeyboardInterrupt:
            pass
    elif command == "start":
        vm = client.call("vm.get", {"name": argv[1]})
        client.call("vm.start", {"name": argv[1], "options": start_options(vm, argv)})
        print(f"started {argv[1]}")
    elif command == "stop":
        mode = "force" if "--force" in argv else "soft"
        client.call("vm.stop", {"name": argv[1], "mode": mode})
        print(f"stop ({mode}) sent to {argv[1]}")
    elif command == "call":
        try:
            result = client.call(method, params)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
