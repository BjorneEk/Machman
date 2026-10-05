//
//  LabControlServerTests.swift
//  MachmanCoreTests
//
//  TB11: the test-suite agent's control socket answers one line per command line, in order,
//  over a real socket in the run's scratch space; a line that doesn't parse is answered with
//  its reason and never reaches the agent.
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
}
