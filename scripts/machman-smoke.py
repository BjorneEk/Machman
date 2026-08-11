#!/usr/bin/env python3
"""Non-Swift proof for the Machman daemon protocol (stdlib only).

Usage:
  machman-smoke.py [--socket PATH] [info]        hello + list VMs (default)
  machman-smoke.py [--socket PATH] watch         subscribe and stream events (^C to stop)
  machman-smoke.py [--socket PATH] start NAME [--headless]
  machman-smoke.py [--socket PATH] stop NAME [--force]

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
                    raise RuntimeError(f"{method}: {msg['error']['message']}")
                return msg.get("result")
            # Anything else (events) while waiting: ignore here.

    def events(self):
        self.call("events.subscribe")
        while True:
            msg = self.read_line()
            if msg.get("method") == "event":
                yield msg["params"]


def main():
    path, argv = socket_path(sys.argv[1:])
    command = argv[0] if argv else "info"
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
        client.call("vm.start", {
            "name": argv[1],
            "options": {"openWindow": "--headless" not in argv}})
        print(f"started {argv[1]}")
    elif command == "stop":
        mode = "force" if "--force" in argv else "soft"
        client.call("vm.stop", {"name": argv[1], "mode": mode})
        print(f"stop ({mode}) sent to {argv[1]}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
