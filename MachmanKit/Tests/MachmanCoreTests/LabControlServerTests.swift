//
//  LabControlServerTests.swift
//  MachmanCoreTests
//
//  TB11: the test-suite agent's control socket answers one line per command line, in order,
//  over a real socket in the run's scratch space; a line that doesn't parse is answered with
//  its reason and never reaches the agent.
//  Q23: what a command sets off after its reply (a quit) waits until the reply is written.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct LabControlServerTests {
	private func connect(_ path: String) -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		_ = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		return fd
	}

	@Test("Q18: the control socket answers one line per command (TB11)")
	func theControlSocketAnswersOneLinePerCommand() async throws {
		let path = TestEnvironment.socketPath("labctl")
		var seen: [LabCommand] = []
		let server = try LabControlServer(path: path) { command in
			seen.append(command)
			if case .menu = command {
				try? await Task.sleep(for: .milliseconds(50))   // slower than the next line
			}
			return "ok"
		}
		defer { server.stop() }
		let fd = connect(path)
		#expect(fd >= 0)
		defer { close(fd) }

		let bytes = Array("ping\nmenu start dev copy\nbogus\n".utf8)
		#expect(write(fd, bytes, bytes.count) == bytes.count)
		let replies = await SocketLines.read(fd, count: 3, timeout: 30)
		#expect(replies == ["ok", "ok", "error unknown command 'bogus'"])
		#expect(seen == [.ping, .menu(.start, vm: "dev copy")])
	}

	@Test("Q18: a second control server on a served path is refused (TB11)")
	func aSecondServerOnAServedPathIsRefused() throws {
		let path = TestEnvironment.socketPath("labctl")
		let first = try LabControlServer(path: path) { _ in "ok" }
		defer { first.stop() }
		#expect(throws: UDSError.self) { try LabControlServer(path: path) { _ in "ok" } }
	}

	@Test("Q18: a lab quit reason is the agent's quit reason (TB11)")
	func aLabQuitReasonIsTheAgentsQuitReason() {
		let map: [LabQuitReason: VMHostQuitReason] = [
			.userQuit: .userQuit, .logOut: .logOut, .restart: .restart, .shutDown: .shutDown,
		]
		for reason in LabQuitReason.allCases {
			#expect(VMHostQuitReason(lab: reason) == map[reason])
		}
	}

	// Q23: a reply sent just before an exit could be lost. The follow-up of a command (the
	// vmhost's quit) runs once its reply is written; a line that doesn't parse has none.
	@Test("Q23: a command's follow-up runs only after its reply is out")
	func aCommandsFollowUpRunsOnlyAfterItsReplyIsOut() async throws {
		let path = TestEnvironment.socketPath("labctl")
		var client: Int32 = -1
		var followed: [(LabCommand, String)] = []
		let server = try LabControlServer(path: path, handler: { _ in "ok" }, afterReply: {
			// What the client could already read when the follow-up ran.
			var buffer = [UInt8](repeating: 0, count: 64)
			let n = recv(client, &buffer, buffer.count, MSG_DONTWAIT)
			followed.append(($0, n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""))
		})
		defer { server.stop() }
		client = connect(path)
		#expect(client >= 0)
		defer { close(client) }

		for line in ["quit logOut", "bogus", "ping"] {
			let bytes = Array((line + "\n").utf8)
			#expect(write(client, bytes, bytes.count) == bytes.count)
			if line == "bogus" {
				#expect(await SocketLines.read(client, count: 1, timeout: 30)
					== ["error unknown command 'bogus'"])
				continue
			}
			let before = followed.count
			for _ in 0..<1000 where followed.count == before {
				try await Task.sleep(for: .milliseconds(10))
			}
		}
		#expect(followed.map(\.0) == [.quit(.logOut), .ping])
		#expect(followed.map(\.1) == ["ok\n", "ok\n"])
	}

	@Test("Q23: a sent line's completion says whether it was written")
	func aSentLinesCompletionSaysWhetherItWasWritten() async throws {
		var pair: [Int32] = [-1, -1]
		#expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
		defer { close(pair[1]) }
		let connection = UDSConnection(fd: pair[0])
		connection.start()
		let written = await withCheckedContinuation { done in
			connection.send(Data("ok".utf8)) { done.resume(returning: $0) }
		}
		#expect(written)
		var buffer = [UInt8](repeating: 0, count: 8)
		#expect(recv(pair[1], &buffer, buffer.count, MSG_DONTWAIT) == 3)   // there already
		connection.shutdown()
		let dropped = await withCheckedContinuation { done in
			connection.send(Data("late".utf8)) { done.resume(returning: $0) }
		}
		#expect(!dropped)
	}
}
