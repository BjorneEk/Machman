//
//  SmokeScriptCallTests.swift
//  MachmanAPITests
//
//  scripts/machman-smoke.py is the documented way to try the protocol by hand
//  (docs/ipc-protocol.md's quick start). Its `call` sends any request and prints the result,
//  so the doc's examples are only as good as that command: here it talks to a stand-in daemon
//  (a unix socket server inside the same python process) and its output is read back.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport

// L1: the script under python3 against a stand-in daemon.
struct SmokeScriptCallTests {
	// The stand-in answers hello, refuses `vm.nope` the way the daemon refuses an unknown VM
	// (machmanCode in the error's data), and otherwise answers with the request it got.
	static let harness = """
		import contextlib, importlib.util, io, json, os, socket, sys, tempfile, threading
		spec = importlib.util.spec_from_file_location("smoke", sys.argv[1])
		smoke = importlib.util.module_from_spec(spec)
		spec.loader.exec_module(smoke)
		path = os.path.join(tempfile.mkdtemp(prefix="s"), "d.sock")
		server = socket.socket(socket.AF_UNIX)
		server.bind(path)
		server.listen(4)
		def serve():
		    while True:
		        conn, _ = server.accept()
		        stream = conn.makefile("rwb")
		        for line in stream:
		            req = json.loads(line)
		            if req["method"] == "machman.hello":
		                reply = {"result": {"apiVersion": 1, "daemonVersion": "test"}}
		            elif req["method"] == "vm.nope":
		                reply = {"error": {"code": -32000, "message": "No VM named nope",
		                    "data": {"machmanCode": "notFound"}}}
		            else:
		                reply = {"result": {"method": req["method"], "params": req.get("params")}}
		            reply.update(jsonrpc="2.0", id=req["id"])
		            stream.write((json.dumps(reply) + "\\n").encode())
		            stream.flush()
		threading.Thread(target=serve, daemon=True).start()
		def run(args):
		    out, err = io.StringIO(), io.StringIO()
		    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
		        status = smoke.main(["--socket", path] + args)
		    return {"status": status, "out": out.getvalue(), "err": err.getvalue()}
		sys.stdout.write(json.dumps({
		    "answered": run(["call", "vm.get", '{"name": "alpha"}']),
		    "bare": run(["call", "host.capabilities"]),
		    "refused": run(["call", "vm.nope", "{}"]),
		    "malformed": run(["call", "vm.get", "{not json"]),
		}))
		"""

	struct Run: Decodable {
		let status: Int
		let out: String
		let err: String
	}

	@Test("A17: machman-smoke.py call sends any request and prints its result")
	func callSendsAnyRequest() async throws {
		let result = try await Subprocess.run(
			"/usr/bin/python3",
			["-I", "-B", "-c", Self.harness, RepoFiles.url("scripts/machman-smoke.py").path])
		#expect(result.status == 0, "\(result.output)")
		let runs = try JSONDecoder().decode(
			[String: Run].self, from: Data(result.output.utf8))

		// The method and the params as given, and the result printed as JSON.
		let answered = try #require(runs["answered"])
		#expect(answered.status == 0, "\(answered.err)")
		let echoed = try JSONSerialization.jsonObject(with: Data(answered.out.utf8))
			as? [String: Any]
		#expect(echoed?["method"] as? String == "vm.get")
		#expect((echoed?["params"] as? [String: String]) == ["name": "alpha"])

		// No params: the request carries none.
		let bare = try #require(runs["bare"])
		#expect(bare.status == 0, "\(bare.err)")
		let bareEcho = try JSONSerialization.jsonObject(with: Data(bare.out.utf8))
			as? [String: Any]
		#expect(bareEcho?["method"] as? String == "host.capabilities")
		#expect(bareEcho?["params"] is NSNull)

		// A refusal: exit 1, the message and Machman's own code on stderr, nothing on stdout.
		let refused = try #require(runs["refused"])
		#expect(refused.status == 1)
		#expect(refused.out.isEmpty)
		#expect(refused.err.contains("vm.nope: No VM named nope (notFound)"), "\(refused.err)")

		// Params that aren't JSON: the usage, exit 2, and no request sent.
		let malformed = try #require(runs["malformed"])
		#expect(malformed.status == 2)
		#expect(malformed.out.contains("call METHOD [PARAMS]"))
	}
}
