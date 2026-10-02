//
//  RPCTimeoutTests.swift
//  MachmanTests
//
//  The E5 family over a real unix socket: a listener that accepts but never (or late)
//  replies. Deadlines fail the one call, cancellation abandons the wait, the connection
//  survives both, and late replies for abandoned ids are dropped — never misdelivered.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanClient

// A scriptable peer: accepts one connection, parses request ids off the wire, and replies
// only when the test says so. Everything the reader thread touches is lock-guarded.
private final class SilentServer: @unchecked Sendable {
	let socketPath: String
	private let listenFD: Int32
	private let lock = NSLock()
	private var connFD: Int32 = -1
	private var requestIDs: [Int] = []
	private var buffer = Data()

	init() throws {
		socketPath = TestEnvironment.socketPath("mm-silent")
		listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(listenFD, 4) == 0 else {
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		let fd = listenFD
		Thread.detachNewThread { [weak self] in
			let conn = accept(fd, nil, nil)
			guard conn >= 0 else { return }
			self?.setConn(conn)
			var chunk = [UInt8](repeating: 0, count: 4096)
			while true {
				let n = read(conn, &chunk, chunk.count)
				if n <= 0 { break }
				self?.ingest(Data(chunk[0..<n]))
			}
		}
	}

	private func setConn(_ fd: Int32) {
		lock.lock(); connFD = fd; lock.unlock()
	}

	private func ingest(_ data: Data) {
		lock.lock()
		defer { lock.unlock() }
		buffer.append(data)
		while let newline = buffer.firstIndex(of: 0x0A) {
			let line = buffer.subdata(in: buffer.startIndex..<newline)
			buffer.removeSubrange(buffer.startIndex...newline)
			if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
				let id = obj["id"] as? Int {
				requestIDs.append(id)
			}
		}
	}

	// Ids seen so far, oldest first.
	var seenIDs: [Int] {
		lock.lock(); defer { lock.unlock() }
		return requestIDs
	}

	// Reply to one id with an empty result (the vm.stop/void shape).
	func reply(id: Int) {
		lock.lock()
		let fd = connFD
		lock.unlock()
		guard fd >= 0 else { return }
		let line = #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"# + "\n"
		_ = line.withCString { write(fd, $0, strlen($0)) }
	}

	func close() {
		lock.lock()
		if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
		lock.unlock()
		Darwin.close(listenFD)
		unlink(socketPath)
	}

	// Wait (bounded) until the server has seen `count` requests.
	func waitForRequests(_ count: Int) async {
		for _ in 0..<200 {
			if seenIDs.count >= count { return }
			try? await Task.sleep(for: .milliseconds(25))
		}
	}
}

struct RPCTimeoutTests {

	// The deadline fires with the timeout code, the connection is NOT torn down, and a
	// later (good) reply on the same connection still round-trips — one hung reply must
	// cost one call, nothing else.
	@Test func deadlineFailsOnlyThatCall() async throws {
		let server = try SilentServer()
		defer { server.close() }
		let disconnects = DisconnectCounter()
		let connection = try RPCConnection(socketPath: server.socketPath) {
			disconnects.increment()
		}

		do {
			_ = try await connection.call(
				.vmList, RPCEmpty?.none, expecting: RPCEmpty.self,
				deadline: .milliseconds(300))
			Issue.record("expected a timeout")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
			#expect(error.message.contains("vm.list"))
		}
		#expect(disconnects.count == 0)

		// The connection still works: the server answers the SECOND call promptly.
		await server.waitForRequests(1)
		let second = Task {
			try await connection.call(
				.stop, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(10))
		}
		await server.waitForRequests(2)
		let ids = server.seenIDs
		#expect(ids.count == 2)
		server.reply(id: ids[1])
		_ = try await second.value
		#expect(disconnects.count == 0)
		await connection.disconnect()
	}

	// A reply that arrives after its call was abandoned is dropped: it must not resume
	// anything, corrupt the pending table, or get delivered to a later call.
	@Test func lateReplyForAbandonedIDIsIgnored() async throws {
		let server = try SilentServer()
		defer { server.close() }
		let connection = try RPCConnection(socketPath: server.socketPath) {}

		do {
			_ = try await connection.call(
				.vmList, RPCEmpty?.none, expecting: RPCEmpty.self,
				deadline: .milliseconds(200))
			Issue.record("expected a timeout")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
		}
		await server.waitForRequests(1)
		let abandoned = server.seenIDs[0]
		// The late reply for the abandoned id, then the reply for the live call.
		server.reply(id: abandoned)
		let second = Task {
			try await connection.call(
				.stop, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(10))
		}
		await server.waitForRequests(2)
		server.reply(id: server.seenIDs[1])
		_ = try await second.value   // resolves via ITS reply; the stale one changed nothing
		await connection.disconnect()
	}

	// Cancelling the calling task abandons the wait immediately — the in-flight-guard
	// wedge (P7): a caller must be able to give up without waiting out the deadline.
	@Test func cancellationAbandonsTheWait() async throws {
		let server = try SilentServer()
		defer { server.close() }
		let connection = try RPCConnection(socketPath: server.socketPath) {}

		let call = Task {
			try await connection.call(
				.vmList, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(60))
		}
		await server.waitForRequests(1)
		call.cancel()
		let outcome = await call.result
		guard case .failure(let error) = outcome else {
			Issue.record("expected the cancelled call to fail")
			return
		}
		#expect(error is CancellationError)

		// The connection survives the abandonment.
		let second = Task {
			try await connection.call(
				.stop, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(10))
		}
		await server.waitForRequests(2)
		server.reply(id: server.seenIDs[1])
		_ = try await second.value
		await connection.disconnect()
	}

	// An unknown-id reply out of nowhere (no call ever pending) is likewise ignored.
	@Test func unknownIDReplyIsIgnored() async throws {
		let server = try SilentServer()
		defer { server.close() }
		let connection = try RPCConnection(socketPath: server.socketPath) {}

		let first = Task {
			try await connection.call(
				.stop, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(10))
		}
		await server.waitForRequests(1)
		server.reply(id: 424242)              // never issued
		server.reply(id: server.seenIDs[0])   // the real one
		_ = try await first.value
		await connection.disconnect()
	}
}

private final class DisconnectCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	func increment() { lock.lock(); value += 1; lock.unlock() }
	var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
