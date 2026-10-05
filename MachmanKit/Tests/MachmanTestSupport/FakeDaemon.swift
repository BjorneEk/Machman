//
//  FakeDaemon.swift
//  MachmanTestSupport
//
//  A scripted stand-in for Machman Agent's socket: a UNIX socket in the run's scratch space
//  speaking newline-framed JSON-RPC, so a test drives the real client (RemoteMachman, the
//  desktop's connect loop) against an agent that answers, stalls, drops mid-call, sends
//  events, or isn't there at all. Each accepted connection takes the next script (then
//  `otherwise`); a script maps methods to replies. Every request is recorded.
//
//  Foundation only (no MachmanAPI): the typed helpers — a hello, an event's params — live
//  beside the tests that need them (DesktopCoreTests' FakeDaemon+Machman.swift).
//
//  Threads, never the cooperative pool: the accept loop polls a non-blocking listener every
//  100 ms on a thread of its own, and each connection's reader blocks in read() on its own.
//  No descriptor is closed under a thread that may still use it: the accept thread closes
//  its listener, the reader closes its connection (a drop only shuts it down, which wakes
//  the reader), and writes check under the connection's lock that the reader hasn't.
//  Unlike MachmanClientTests' one-connection ScriptedPeer, it serves any number of them.
//

import Foundation

public final class FakeDaemon: @unchecked Sendable {
	public indirect enum Reply: Sendable {
		case result(String)   // the result's JSON
		case error(code: Int, message: String, dataJSON: String? = nil)
		case stall            // never answers
		case drop             // closes the connection instead of answering
		case after(Duration, Reply)

		public static let methodNotFound = Reply.error(code: -32601, message: "Method not found")
	}

	public struct Script: Sendable {
		public var replies: [String: Reply]
		public var otherwise: Reply

		public init(replies: [String: Reply] = [:], otherwise: Reply = .methodNotFound) {
			self.replies = replies
			self.otherwise = otherwise
		}

		func reply(to method: String) -> Reply {
			replies[method] ?? otherwise
		}
	}

	public struct Request: Sendable, Equatable {
		public let connection: Int   // 1 = the first connection accepted
		public let id: Int?          // nil for a notification (or a string id)
		public let method: String
		public let params: String?   // the params as sorted-keys JSON; nil when absent

		public init(connection: Int, id: Int?, method: String, params: String?) {
			self.connection = connection
			self.id = id
			self.method = method
			self.params = params
		}
	}

	public let socketPath: String
	private let lock = NSLock()
	private var queued: [Script] = []
	private var fallback = Script()
	private var listener: Listener?
	private var connections: [Int: Connection] = [:]
	private var accepted = 0
	private var recorded: [Request] = []
	private var waiters: [UUID: Waiter] = [:]

	// The scripts the next connections take, in order; then `otherwise`. Both can change at
	// any time and apply to connections accepted later.
	public var scripts: [Script] {
		get { lock.withLock { queued } }
		set { lock.withLock { queued = newValue } }
	}

	public var otherwise: Script {
		get { lock.withLock { fallback } }
		set { lock.withLock { fallback = newValue } }
	}

	public var connectionCount: Int { lock.withLock { accepted } }

	public var requests: [Request] { lock.withLock { recorded } }

	// `listening: false` leaves the path free: a client connecting reads "no such file", as
	// with an agent that isn't running, until listen().
	public init(
		socketPath: String = TestEnvironment.socketPath("mm-fd"), listening: Bool = true
	) throws {
		self.socketPath = socketPath
		if listening { try listen() }
	}

	deinit {
		close()
		for waiter in waiters.values {
			waiter.continuation.resume(returning: false)
		}
	}

	// MARK: - Listening

	private final class Listener: @unchecked Sendable {
		let fd: Int32
		let device: dev_t
		let inode: ino_t
		private let lock = NSLock()
		private var stopped = false

		init(fd: Int32, device: dev_t, inode: ino_t) {
			self.fd = fd
			self.device = device
			self.inode = inode
		}

		var isStopped: Bool { lock.withLock { stopped } }

		func stop() { lock.withLock { stopped = true } }
	}

	public func listen() throws {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw Self.failure("socket", errno) }
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let capacity = MemoryLayout.size(ofValue: address.sun_path)
		guard socketPath.utf8.count < capacity else {
			Darwin.close(fd)
			throw Self.failure("bind \(socketPath)", ENAMETOOLONG)
		}
		withUnsafeMutablePointer(to: &address.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, capacity) }
			}
		}
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		var info = stat()
		guard bound, Darwin.listen(fd, SOMAXCONN) == 0, stat(socketPath, &info) == 0 else {
			let err = errno
			Darwin.close(fd)
			throw Self.failure("listen on \(socketPath)", err)
		}
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		let listener = Listener(fd: fd, device: info.st_dev, inode: info.st_ino)
		let previous = lock.withLock { () -> Listener? in
			defer { self.listener = listener }
			return self.listener
		}
		previous?.stop()
		let path = socketPath
		Thread.detachNewThread { [weak self] in
			while !listener.isStopped, self != nil {
				var poller = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
				guard poll(&poller, 1, 100) > 0 else { continue }
				let fd = accept(listener.fd, nil, nil)
				guard fd >= 0 else { continue }
				// An accepted socket inherits the listener's O_NONBLOCK; its reader blocks.
				_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
				guard let self, !listener.isStopped else {
					Darwin.close(fd)
					break
				}
				self.serve(fd)
			}
			Darwin.close(listener.fd)
			Self.unlinkIfOurs(path, listener)
		}
	}

	// New connects fail at once ("no such file": the path goes now); the accept thread
	// closes the listener on its next poll. Connections already accepted stay up.
	public func stopListening() {
		guard let listener = lock.withLock({ () -> Listener? in
			defer { self.listener = nil }
			return self.listener
		}) else { return }
		listener.stop()
		Self.unlinkIfOurs(socketPath, listener)
	}

	// The path goes only while it is still the socket this listener bound.
	private static func unlinkIfOurs(_ path: String, _ listener: Listener) {
		var info = stat()
		if stat(path, &info) == 0, info.st_dev == listener.device,
			info.st_ino == listener.inode {
			unlink(path)
		}
	}

	// MARK: - Connections

	private final class Connection: @unchecked Sendable {
		let number: Int
		let script: Script
		private let fd: Int32
		private let lock = NSLock()
		private var closed = false

		init(number: Int, fd: Int32, script: Script) {
			self.number = number
			self.fd = fd
			self.script = script
			var on: Int32 = 1
			_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		}

		func send(_ line: String) {
			lock.withLock {
				guard !closed else { return }
				let bytes = Array((line + "\n").utf8)
				var offset = 0
				while offset < bytes.count {
					let n = bytes[offset...].withUnsafeBytes {
						write(fd, $0.baseAddress, $0.count)
					}
					if n <= 0 { break }
					offset += n
				}
			}
		}

		// Wakes the reader with EOF; the reader closes.
		func drop() {
			lock.withLock {
				if !closed { _ = shutdown(fd, SHUT_RDWR) }
			}
		}

		// The reader's loop: blocking reads until EOF, each complete line handed on.
		func run(_ line: (Data) -> Void) {
			var buffer = Data()
			var chunk = [UInt8](repeating: 0, count: 16 * 1024)
			while true {
				let n = read(fd, &chunk, chunk.count)
				if n <= 0 { break }
				buffer.append(contentsOf: chunk[0..<n])
				while let newline = buffer.firstIndex(of: 0x0A) {
					let data = buffer.subdata(in: buffer.startIndex..<newline)
					buffer.removeSubrange(buffer.startIndex...newline)
					if !data.isEmpty { line(data) }
				}
			}
			lock.withLock {
				closed = true
				Darwin.close(fd)
			}
		}
	}

	private func serve(_ fd: Int32) {
		let connection = lock.withLock { () -> Connection in
			accepted += 1
			let script = queued.isEmpty ? fallback : queued.removeFirst()
			let connection = Connection(number: accepted, fd: fd, script: script)
			connections[accepted] = connection
			return connection
		}
		settleWaiters()
		Thread.detachNewThread { [weak self] in
			connection.run { self?.handle($0, on: connection) }
			guard let self else { return }
			_ = lock.withLock { self.connections.removeValue(forKey: connection.number) }
		}
	}

	private func handle(_ line: Data, on connection: Connection) {
		guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
			let method = object["method"] as? String
		else { return }
		let rawID = object["id"]
		let request = Request(
			connection: connection.number, id: rawID as? Int, method: method,
			params: Self.json(object["params"], sorted: true))
		lock.withLock { recorded.append(request) }
		settleWaiters()
		// A notification (no id) is never answered.
		guard let rawID, !(rawID is NSNull), let id = Self.json(rawID, sorted: false) else {
			return
		}
		respond(connection.script.reply(to: method), id: id, on: connection)
	}

	private func respond(_ reply: Reply, id: String, on connection: Connection) {
		switch reply {
		case .result(let json):
			connection.send(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(json)}"#)
		case .error(let code, let message, let dataJSON):
			let text = Self.json(message, sorted: false) ?? "\"\""
			let data = dataJSON.map { #","data":\#($0)"# } ?? ""
			let error = #"{"code":\#(code),"message":\#(text)\#(data)}"#
			connection.send(#"{"jsonrpc":"2.0","id":\#(id),"error":\#(error)}"#)
		case .stall:
			break
		case .drop:
			connection.drop()
		case .after(let delay, let next):
			let (seconds, attoseconds) = delay.components
			let wait = Double(seconds) + Double(attoseconds) / 1e18
			DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
				self?.respond(next, id: id, on: connection)
			}
		}
	}

	// MARK: - Driving

	// A notification to every live connection, e.g. ("event", <a VMEvent's JSON>).
	public func notify(_ method: String, paramsJSON: String) {
		let name = Self.json(method, sorted: false) ?? "\"\""
		let line = #"{"jsonrpc":"2.0","method":\#(name),"params":\#(paramsJSON)}"#
		for connection in lock.withLock({ Array(connections.values) }) {
			connection.send(line)
		}
	}

	// Every live connection goes away (its client reads EOF); the listener stays.
	public func dropAll() {
		for connection in lock.withLock({ Array(connections.values) }) {
			connection.drop()
		}
	}

	public func close() {
		stopListening()
		dropAll()
	}

	// MARK: - Waiting

	private struct Waiter {
		let done: () -> Bool   // read under the lock
		let continuation: CheckedContinuation<Bool, Never>
	}

	// True once `count` requests for `method` have arrived; false at the timeout.
	public func waitForRequest(
		_ method: String, count: Int = 1, timeout: Duration = .seconds(10)
	) async -> Bool {
		await wait(timeout: timeout) { [unowned self] in
			recorded.count(where: { $0.method == method }) >= count
		}
	}

	// True once `n` connections were accepted in all; false at the timeout.
	public func waitForConnections(_ n: Int, timeout: Duration = .seconds(10)) async -> Bool {
		await wait(timeout: timeout) { [unowned self] in accepted >= n }
	}

	private func wait(timeout: Duration, until done: @escaping () -> Bool) async -> Bool {
		let id = UUID()
		return await withCheckedContinuation { continuation in
			let now = lock.withLock { () -> Bool in
				if done() { return true }
				waiters[id] = Waiter(done: done, continuation: continuation)
				return false
			}
			if now {
				continuation.resume(returning: true)
				return
			}
			let (seconds, attoseconds) = timeout.components
			let wait = Double(seconds) + Double(attoseconds) / 1e18
			DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
				guard let self else { return }
				let expired = lock.withLock { self.waiters.removeValue(forKey: id) }
				expired?.continuation.resume(returning: false)
			}
		}
	}

	private func settleWaiters() {
		let ready = lock.withLock { () -> [Waiter] in
			let ids = waiters.filter { $0.value.done() }.map(\.key)
			return ids.compactMap { waiters.removeValue(forKey: $0) }
		}
		for waiter in ready {
			waiter.continuation.resume(returning: true)
		}
	}

	// MARK: - JSON

	private static func json(_ value: Any?, sorted: Bool) -> String? {
		guard let value, !(value is NSNull) else { return nil }
		var options: JSONSerialization.WritingOptions = [
			.fragmentsAllowed, .withoutEscapingSlashes,
		]
		if sorted { options.insert(.sortedKeys) }
		guard let data = try? JSONSerialization.data(withJSONObject: value, options: options)
		else { return nil }
		return String(decoding: data, as: UTF8.self)
	}

	private static func failure(_ what: String, _ err: Int32) -> NSError {
		NSError(
			domain: NSPOSIXErrorDomain, code: Int(err),
			userInfo: [NSLocalizedDescriptionKey:
				"FakeDaemon: \(what): \(String(cString: strerror(err)))"])
	}
}
