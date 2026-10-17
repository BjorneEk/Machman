//
//  RPCConnection.swift
//  MachmanClient
//
//  One JSON-RPC connection to the daemon's unix socket: id-matched request/response plus
//  fan-out of "event" notifications. A dedicated reader thread feeds the actor; everything
//  else is actor-isolated.
//
//  The reader thread holds the raw descriptor number for as long as it runs, so teardown
//  never closes it (E26): a closed number is reused by the next open() in the process, and
//  the reader's next read() would steal that file's or socket's bytes. Teardown shuts the
//  socket down instead — that wakes a blocked read with EOF and keeps the number reserved —
//  and whichever side finishes second, the reader leaving its loop or the owner's shutdown,
//  closes it (SocketLifetime).
//

import Foundation
import MachmanAPI

// The descriptor's two holders, the reader thread and the actor's teardown; the second one
// to let go closes it, exactly once.
private final class SocketLifetime: @unchecked Sendable {
	let fd: Int32
	private let lock = NSLock()
	private var readerDone = false
	private var shutDown = false
	private var closed = false

	init(fd: Int32) {
		self.fd = fd
	}

	var isClosed: Bool {
		lock.withLock { closed }
	}

	// The owner is done: wake the reader (a blocked read returns EOF) without freeing the
	// number it may still read from.
	func shutDownByOwner() {
		lock.withLock {
			if !shutDown {
				shutDown = true
				_ = Darwin.shutdown(fd, SHUT_RDWR)
			}
			closeIfDone()
		}
	}

	// The reader thread left its loop for good.
	func readerFinished() {
		lock.withLock {
			readerDone = true
			closeIfDone()
		}
	}

	// Lock held.
	private func closeIfDone() {
		guard readerDone, shutDown, !closed else { return }
		closed = true
		close(fd)
	}
}

public actor RPCConnection {
	// Every process links this (the desktop and the agent to the agent, the agent to its
	// vmhosts), so neither text names the peer. The description, with the socket path, is
	// for logs; the localized text is what a person reads.
	public enum ConnectionError: Error, CustomStringConvertible, LocalizedError {
		case connectFailed(String, Int32)
		case disconnected

		public var description: String {
			switch self {
			case .connectFailed(let path, let err):
				return "cannot connect to \(path): \(String(cString: strerror(err)))"
			case .disconnected:
				return "the connection was lost"
			}
		}

		public var errorDescription: String? {
			switch self {
			case .connectFailed(_, let err):
				return "Can’t connect: \(String(cString: strerror(err)))"
			case .disconnected:
				return "The connection was lost"
			}
		}
	}

	// Every call is bounded (E5): a peer that accepted the connection but stopped answering
	// must fail THAT call, not park it forever — an unbounded wait wedges the daemon's quit
	// path and every client's in-flight guard behind one hung vmhost.
	public static let defaultCallDeadline: Duration = .seconds(30)
	// For calls that legitimately run long: forwarded boots, shadow builds, and whole-disk
	// byte copies (cross-volume copy/import/promote/safe-save, Rosetta download). Generous
	// on purpose — the deadline exists to break wedges, never to cut off honest work.
	public static let slowCallDeadline: Duration = .seconds(3600)

	private struct PendingCall {
		let continuation: CheckedContinuation<Data, Error>
		let timer: Task<Void, Never>
		let method: RPCMethod
		let request: Data   // the line as sent, for the interrupted-call record
	}

	private nonisolated let socket: SocketLifetime
	// What a call's deadline runs on: the wall clock, or a test's clock (Q40).
	private nonisolated let clock: any Clock<Duration>
	// The pid on the other end of the socket, captured once at connect. The daemon's
	// safe-run sweep matches it against shadow markers — exact peer identity with no wire
	// change. nil only if the getsockopt fails.
	public nonisolated let peerPID: Int32?
	private var nextID = 1
	private var pending: [Int: PendingCall] = [:]
	private var eventSubscribers: [UUID: AsyncStream<VMEvent>.Continuation] = [:]
	// Subscribers that also want each event's line as it arrived (A10: the daemon passes a
	// vmhost's events on by that line).
	private var lineSubscribers: [UUID: AsyncStream<EventLine>.Continuation] = [:]
	private var closed = false
	// What the connection's death cut off: the calls still waiting for a reply at teardown,
	// oldest first (P12). Empty while the connection lives.
	private var interrupted: [InterruptedCall] = []
	// Fired once when the connection dies (EOF, write failure) — after pending calls fail.
	private let onDisconnect: @Sendable () -> Void

	// How long one write may go without progress before the connection counts as lost: a
	// peer that stopped reading must not hold this actor in write() (E17).
	public static let defaultSendTimeout: Duration = .seconds(10)

	public init(
		socketPath: String, sendTimeout: Duration = RPCConnection.defaultSendTimeout,
		clock: any Clock<Duration> = ContinuousClock(),
		onDisconnect: @escaping @Sendable () -> Void = {}
	) throws {
		try self.init(
			socketPath: socketPath, sendTimeout: sendTimeout, clock: clock, readerHook: nil,
			onDisconnect: onDisconnect)
	}

	// The designated init. readerHook is a test seam: it runs on the reader thread after
	// each chunk the reader processed, so a test can park the reader between reads. So is
	// onConnected: it gets the connected socket before the reader starts, while nothing can
	// have closed it yet — a host that hangs up at once has it torn down right after.
	init(
		socketPath: String, sendTimeout: Duration,
		clock: any Clock<Duration> = ContinuousClock(), readerHook: (@Sendable () -> Void)?,
		onConnected: ((Int32) -> Void)? = nil, onDisconnect: @escaping @Sendable () -> Void
	) throws {
		self.onDisconnect = onDisconnect
		self.clock = clock

		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
		guard socketPath.utf8.count <= maxLen else {
			throw ConnectionError.connectFailed(socketPath, ENAMETOOLONG)
		}
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, maxLen + 1) }
			}
		}
		let fd = Self.newSocket(sendTimeout: sendTimeout)
		guard fd >= 0 else { throw ConnectionError.connectFailed(socketPath, errno) }
		let connected = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard connected else {
			let err = errno
			close(fd)
			throw ConnectionError.connectFailed(socketPath, err)
		}
		onConnected?(fd)
		self.socket = SocketLifetime(fd: fd)
		var pid: pid_t = 0
		var len = socklen_t(MemoryLayout<pid_t>.size)
		// LOCAL_PEERPID: hard-coded 0x002 — stable Darwin ABI, the constant does not
		// always import from <sys/un.h>.
		if getsockopt(fd, SOL_LOCAL, 0x002, &pid, &len) == 0 {
			self.peerPID = pid
		} else {
			self.peerPID = nil
		}

		// Reader thread feeds an ordered line stream; a single task drains it into the actor,
		// preserving on-wire order for events and responses alike.
		let socket = self.socket
		let (lines, feed) = AsyncStream<Data>.makeStream()
		Thread.detachNewThread {
			var buffer = Data()
			var chunk = [UInt8](repeating: 0, count: 64 * 1024)
			while true {
				let n = read(socket.fd, &chunk, chunk.count)
				if n <= 0 { break }
				buffer.append(contentsOf: chunk[0..<n])
				while let newline = buffer.firstIndex(of: 0x0A) {
					let line = buffer.subdata(in: buffer.startIndex..<newline)
					buffer.removeSubrange(buffer.startIndex...newline)
					if !line.isEmpty {
						feed.yield(line)
					}
				}
				readerHook?()
			}
			socket.readerFinished()
			feed.finish()
		}
		Task { [weak self] in
			for await line in lines {
				await self?.dispatch(line: line)
			}
			await self?.teardown()
		}
	}

	// A socket set up for its connection before it connects: no write progress for sendTimeout
	// fails the write with EAGAIN, and a write to a peer that left fails with EPIPE instead of
	// raising SIGPIPE in the whole process. Before the connect, never after: Darwin refuses
	// SO_NOSIGPIPE (EINVAL) on a socket whose peer already hung up, so a host that accepted and
	// left at once (one exiting, one that never serves) killed the client on its first write.
	// -1 with errno when there is no socket.
	nonisolated static func newSocket(sendTimeout: Duration) -> Int32 {
		let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return fd }
		let (seconds, attoseconds) = sendTimeout.components
		var timeout = timeval(
			tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
		_ = setsockopt(
			fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var on: Int32 = 1
		_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		return fd
	}

	// MARK: - Calls

	public func call<P: Codable, R: Codable>(
		_ method: RPCMethod, _ params: P?, expecting: R.Type,
		deadline: Duration = RPCConnection.defaultCallDeadline
	) async throws -> R {
		// An error reply already failed the wait (dispatch read it); this is the one typed read.
		let line = try await roundTrip(method, params, deadline: deadline)
		return try MachmanWire.decoder().decode(RPCResult<R>.self, from: line).result
	}

	private func roundTrip<P: Codable>(
		_ method: RPCMethod, _ params: P?, deadline: Duration
	) async throws -> Data {
		guard !closed else { throw ConnectionError.disconnected }
		let id = nextID
		nextID += 1
		let call = RPCCall(id: .number(id), method: method.rawValue, params: params)
		let data = try MachmanWire.encoder().encode(call)
		guard writeLine(data) else {
			teardown()
			throw ConnectionError.disconnected
		}
		// The wait is bounded, and cancelling the calling task abandons it. Both fail ONLY
		// this call: the connection stays up and nothing is torn down — a slow peer is not a
		// dead peer, and escalating here would be destructive (hostGone deletes safe-run
		// state). If the reply arrives later, dispatch drops it as an unknown id.
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let timer = Task { [weak self, clock] in
					try? await clock.sleep(for: deadline)
					guard !Task.isCancelled else { return }
					await self?.expire(id: id, method: method, deadline: deadline)
				}
				pending[id] = PendingCall(
					continuation: continuation, timer: timer, method: method, request: data)
			}
		} onCancel: {
			Task { await self.abandon(id: id) }
		}
	}

	// The message reaches alerts and the connect screen, so it says how long without the
	// method's wire name; the log keeps the method. Clients key on the timeout code.
	private func expire(id: Int, method: RPCMethod, deadline: Duration) {
		guard let call = pending.removeValue(forKey: id) else { return }
		MachmanLogger.log(.passiveWarning,
			"no reply to \(method.rawValue) after \(deadline) — the call was abandoned")
		call.continuation.resume(throwing: MachmanError(
			code: .timeout, message: "No answer within \(Self.spoken(deadline))"))
	}

	// "300 ms", "1 second", "30 seconds".
	static func spoken(_ deadline: Duration) -> String {
		let (seconds, attoseconds) = deadline.components
		guard seconds >= 1 else { return "\(attoseconds / 1_000_000_000_000_000) ms" }
		let whole = seconds + (attoseconds >= 500_000_000_000_000_000 ? 1 : 0)
		return whole == 1 ? "1 second" : "\(whole) seconds"
	}

	private func abandon(id: Int) {
		guard let call = pending.removeValue(forKey: id) else { return }
		call.timer.cancel()
		call.continuation.resume(throwing: CancellationError())
	}

	// A failure means the connection is lost — including EAGAIN, which with SO_SNDTIMEO means
	// the peer took no bytes for the whole send timeout. Unbounded, a peer that stopped
	// reading held this actor in write() for good, and with it every deadline timer that
	// runs on the actor.
	private func writeLine(_ data: Data) -> Bool {
		var payload = data
		payload.append(0x0A)
		return payload.withUnsafeBytes { raw -> Bool in
			var offset = 0
			while offset < raw.count {
				let n = write(socket.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
				if n <= 0 {
					if errno == EINTR { continue }
					return false
				}
				offset += n
			}
			return true
		}
	}

	// MARK: - Incoming

	private func dispatch(line: Data) {
		guard let incoming = try? MachmanWire.decoder().decode(Incoming.self, from: line) else {
			return
		}
		if incoming.id == nil, incoming.method == RPCMethod.event.rawValue {
			if let event = incoming.event {
				for continuation in eventSubscribers.values {
					continuation.yield(event)
				}
				for continuation in lineSubscribers.values {
					continuation.yield(EventLine(event: event, line: line))
				}
			}
			return
		}
		if case .number(let id)? = incoming.id, let call = pending.removeValue(forKey: id) {
			// An error ends the call here; a result goes back as its raw line, for the typed
			// caller to decode. A reply whose id is no longer pending (timed out, cancelled)
			// falls through here and is dropped — abandoning a call must tolerate its late
			// answer.
			call.timer.cancel()
			if let error = incoming.error {
				call.continuation.resume(throwing: error.machmanError)
			} else {
				call.continuation.resume(returning: line)
			}
		}
	}

	// One parse per incoming line (Q5): what routes it, an error reply's error and an event's
	// payload. Only a result is read again, as the caller's own type. Before, a reply was
	// parsed three times (route, error attempt, result) and an event twice.
	private struct Incoming: Decodable {
		let id: RPCID?
		let method: String?
		let error: RPCErrorBody?
		let event: VMEvent?

		private enum CodingKeys: String, CodingKey {
			case id, method, error, params
		}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			id = try c.decodeIfPresent(RPCID.self, forKey: .id)
			method = try c.decodeIfPresent(String.self, forKey: .method)
			error = try c.decodeIfPresent(RPCErrorBody.self, forKey: .error)
			// An event that doesn't decode is dropped, as before; the line still routes.
			event = id == nil && method == RPCMethod.event.rawValue
				? try? c.decodeIfPresent(VMEvent.self, forKey: .params) : nil
		}
	}

	// MARK: - Events

	// A stream asked for after the connection died ends at once (E49): only a live teardown
	// finishes subscribers, so a stored one would wait forever. The builder runs on the actor,
	// so the check can't race the teardown.
	public func events() -> AsyncStream<VMEvent> {
		AsyncStream { continuation in
			guard !self.closed else {
				continuation.finish()
				return
			}
			let id = UUID()
			self.eventSubscribers[id] = continuation
			continuation.onTermination = { _ in
				Task { await self.removeSubscriber(id) }
			}
		}
	}

	// Every event from now on with the line it arrived in, in arrival order; ended at once on a
	// dead connection, like events().
	public func eventLines() -> AsyncStream<EventLine> {
		AsyncStream { continuation in
			guard !self.closed else {
				continuation.finish()
				return
			}
			let id = UUID()
			self.lineSubscribers[id] = continuation
			continuation.onTermination = { _ in
				Task { await self.removeSubscriber(id) }
			}
		}
	}

	private func removeSubscriber(_ id: UUID) {
		eventSubscribers[id] = nil
		lineSubscribers[id] = nil
	}

	// MARK: - Teardown

	private func teardown() {
		guard !closed else { return }
		closed = true
		socket.shutDownByOwner()
		// Recorded before the callers hear: a caller that reacts to its .disconnected (or the
		// owner's onDisconnect) already finds itself on the list. A call whose write failed
		// was never fully sent, never pending, and is not on it.
		interrupted = pending.sorted { $0.key < $1.key }.map { _, call in
			InterruptedCall(method: call.method, vm: Self.peekName(call.request))
		}
		for call in pending.values {
			call.timer.cancel()
			call.continuation.resume(throwing: ConnectionError.disconnected)
		}
		pending.removeAll()
		for continuation in eventSubscribers.values {
			continuation.finish()
		}
		eventSubscribers.removeAll()
		for continuation in lineSubscribers.values {
			continuation.finish()
		}
		lineSubscribers.removeAll()
		onDisconnect()
	}

	public func disconnect() {
		teardown()
	}

	// The calls this connection's death left unanswered; empty while it lives.
	public func interruptedCalls() -> [InterruptedCall] {
		interrupted
	}

	private struct NamePeek: Decodable {
		struct Params: Decodable {
			let name: String?
		}
		let params: Params?
	}

	// The VM a request was about, read back from its own line; nil for anything else.
	private static func peekName(_ line: Data) -> String? {
		(try? MachmanWire.decoder().decode(NamePeek.self, from: line))?.params?.name
	}

	// A connection dropped without disconnect() still ends its reader and frees the socket.
	deinit {
		socket.shutDownByOwner()
	}

	// Test seams: the raw descriptor number, and whether it has been closed.
	nonisolated var fdForTesting: Int32 { socket.fd }
	nonisolated var socketClosedForTesting: Bool { socket.isClosed }
}
