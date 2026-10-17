//
//  EventPassthroughTests.swift
//  MachmanCoreTests
//
//  A10: the daemon passes a vmhost's events on by the line the vmhost sent, so an event type
//  or field this daemon does not know (a newer vmhost) reaches clients whole — re-encoding a
//  decoded `.unknown` used to cut it down to {"type": …}. Events the daemon makes itself still
//  go out encoded. E69: a vmhost's log events are written to the log in the vmhost only.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// A vmhost from the future over a real socket: answers hello and events.subscribe, then sends
// whatever raw lines the test pushes. Reader thread + lock, like ScriptedPeer.
private final class RawVMHostPeer: @unchecked Sendable {
	let socketPath: String
	private let listener: Int32
	private let lock = NSLock()
	private var conn: Int32 = -1
	private var buffer = Data()
	private var subscribed = false

	init() throws {
		socketPath = TestEnvironment.socketPath("mm-raw")
		listener = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(listener, 4) == 0 else {
			Darwin.close(listener)
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		let fd = listener
		Thread.detachNewThread { [weak self] in
			let c = accept(fd, nil, nil)
			guard c >= 0 else { return }
			var on: Int32 = 1
			_ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
			self?.lock.withLock { self?.conn = c }
			var chunk = [UInt8](repeating: 0, count: 4096)
			while true {
				let n = read(c, &chunk, chunk.count)
				if n <= 0 { break }
				self?.ingest(Data(chunk[0..<n]))
			}
			self?.lock.withLock { self?.conn = -1 }
			Darwin.close(c)
		}
	}

	var isSubscribed: Bool { lock.withLock { subscribed } }

	func push(_ line: String) {
		send(line)
	}

	func close() {
		lock.withLock { if conn >= 0 { _ = Darwin.shutdown(conn, SHUT_RDWR) } }
		_ = Darwin.shutdown(listener, SHUT_RDWR)
		Darwin.close(listener)
		unlink(socketPath)
	}

	private func ingest(_ data: Data) {
		var replies: [String] = []
		lock.withLock {
			buffer.append(data)
			while let newline = buffer.firstIndex(of: 0x0A) {
				let line = buffer.subdata(in: buffer.startIndex..<newline)
				buffer.removeSubrange(buffer.startIndex...newline)
				guard let object = try? JSONSerialization.jsonObject(with: line)
						as? [String: Any],
					let id = object["id"] as? Int,
					let method = object["method"] as? String else { continue }
				switch method {
				case RPCMethod.hello.rawValue:
					replies.append(#"{"jsonrpc":"2.0","id":\#(id),"result":"#
						+ #"{"apiVersion":1,"daemonVersion":"9.9.9-vmhost"}}"#)
				case RPCMethod.eventsSubscribe.rawValue:
					subscribed = true
					replies.append(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
				default:
					break
				}
			}
		}
		for reply in replies { send(reply) }
	}

	private func send(_ line: String) {
		lock.withLock {
			guard conn >= 0 else { return }
			let payload = line + "\n"
			_ = payload.withCString { write(conn, $0, strlen($0)) }
		}
	}
}

struct EventPassthroughTests {
	@Test @MainActor func aNewerVMHostsEventReachesClientsWhole() async throws {
		let peer = try RawVMHostPeer()
		defer { peer.close() }
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		routing.socketPathForVM = { _ in peer.socketPath }
		let daemonSocket = TestEnvironment.socketPath("mm-daemon")
		let server = MachmanServer(api: routing, socketPath: daemonSocket, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: daemonSocket, clientName: "a10")
		let lines = await client.eventLines()

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: peer.socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		#expect(await eventually { peer.isSubscribed })

		let future = #"{"jsonrpc":"2.0","method":"event","params":"#
			+ #"{"type":"snapshotTaken","vm":"alpha","snapshot":{"id":"s1","bytes":42}}}"#
		peer.push(future)

		let received = Received()
		let reader = Task { @MainActor in
			for await forwarded in lines {
				if case .unknown(type: "snapshotTaken") = forwarded.event {
					received.line = forwarded.line
				}
				if forwarded.event == .listChanged { received.sawListChanged = true }
			}
		}
		defer { reader.cancel() }
		#expect(await eventually { received.line != nil })
		#expect(received.line == Data(future.utf8))
		// The adoption's own listChanged is the daemon's, not the vmhost's: still encoded.
		#expect(await eventually { received.sawListChanged })
	}

	// E69: a vmhost writes its log events to the unified log itself. The agent passed each on
	// and wrote it again, and the desktop a third time, so every VM warning read three times.
	@Test("E69: a vmhost's log line reaches the agent's clients without a second log write")
	@MainActor func aVMHostsLogLineIsPassedOnNotWrittenAgain() async throws {
		let peer = try RawVMHostPeer()
		defer { peer.close() }
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		routing.socketPathForVM = { _ in peer.socketPath }
		let written = Written()
		routing.registry.events.logSink = { _, line in written.lines.append(line) }
		let heard = Heard()
		let stream = await routing.events()
		let reader = Task { @MainActor in
			for await event in stream { heard.events.append(event) }
		}
		defer { reader.cancel() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: peer.socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		#expect(await eventually { peer.isSubscribed })

		let warning = VMEvent.log(vm: "alpha", level: .warning, message: "alpha started headless")
		let params = String(decoding: try MachmanWire.encoder().encode(warning), as: UTF8.self)
		peer.push(#"{"jsonrpc":"2.0","method":"event","params":"# + params + "}")
		#expect(await eventually { heard.events.contains(warning) })
		#expect(!written.lines.contains { $0.contains("started headless") })

		// What the agent says itself is still written, once.
		routing.registry.events.emit(.log(vm: "alpha", level: .warning, message: "its own line"))
		#expect(written.lines.filter { $0.contains("its own line") } == ["(alpha) its own line"])
	}
}

@MainActor
private final class Written {
	var lines: [String] = []
}

@MainActor
private final class Heard {
	var events: [VMEvent] = []
}

@MainActor
private final class Received {
	var line: Data?
	var sawListChanged = false
}
