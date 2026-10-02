//
//  RPCWriteBoundTests.swift
//  MachmanTests
//
//  E17, client side: a request written to a peer that stopped reading must fail once the
//  send timeout passes with no progress. A blocked write used to hold the connection's actor
//  forever — and with it every deadline timer that runs on that actor.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanClient

// Accepts one connection and never reads from it: writes stall once the socket buffers fill.
private final class DeafServer: @unchecked Sendable {
	let socketPath: String
	private let lock = NSLock()
	private var listenFD: Int32 = -1
	private var connFD: Int32 = -1

	init() throws {
		socketPath = TestEnvironment.scratch
			+ "mm-deaf-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, 4) == 0 else {
			Darwin.close(fd)
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		listenFD = fd
		Thread.detachNewThread { [weak self] in
			let conn = accept(fd, nil, nil)
			guard conn >= 0 else { return }
			self?.setConn(conn)
		}
	}

	private func setConn(_ fd: Int32) {
		lock.lock(); connFD = fd; lock.unlock()
	}

	// Idempotent: every descriptor closes once.
	func close() {
		lock.lock()
		defer { lock.unlock() }
		if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
		if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(socketPath) }
	}
}

private final class Flag: @unchecked Sendable {
	private let lock = NSLock()
	private var raised = false
	func raise() { lock.lock(); raised = true; lock.unlock() }
	var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

struct RPCWriteBoundTests {
	@Test @MainActor func aPeerThatStopsReadingFailsTheCall() async throws {
		signal(SIGPIPE, SIG_IGN)   // a write to a closed peer must not kill the test runner
		let server = try DeafServer()
		defer { server.close() }
		let connection = try RPCConnection(
			socketPath: server.socketPath, sendTimeout: .milliseconds(300))
		let finished = Flag()
		// About 1 MiB in one request line: far more than the socket buffers take. Detached:
		// the call needs only the connection's actor, never a main actor the parallel suite
		// keeps busy.
		let call = Task.detached {
			defer { finished.raise() }
			_ = try await connection.call(
				.vmGet, RPCParams.Name(name: String(repeating: "x", count: 1 << 20)),
				expecting: RPCEmpty.self, deadline: .seconds(30))
		}
		// The 300 ms send timeout ends it at once; the bound only has to stay under the 10 s
		// default, which a write ignoring the parameter would wait out.
		#expect(await eventually(timeout: .seconds(8)) { finished.isRaised })

		server.close()   // frees a write that is still blocked, so the task can end
		let outcome = await call.result
		guard case .failure(let error) = outcome else {
			Issue.record("expected the call to fail")
			return
		}
		guard let connectionError = error as? RPCConnection.ConnectionError,
			case .disconnected = connectionError else {
			Issue.record("expected disconnected, got \(error)")
			return
		}
	}
}
