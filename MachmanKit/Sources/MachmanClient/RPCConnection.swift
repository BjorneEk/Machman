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
	public enum ConnectionError: Error, CustomStringConvertible {
		case connectFailed(String, Int32)
		case disconnected

		public var description: String {
			switch self {
			case .connectFailed(let path, let err):
				return "cannot reach MachmanAgent at \(path): \(String(cString: strerror(err)))"
			case .disconnected:
				return "the daemon connection was lost"
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
	}

	private nonisolated let socket: SocketLifetime
	// The pid on the other end of the socket, captured once at connect. The daemon's
	// safe-run sweep matches it against shadow markers — exact peer identity with no wire
	// change. nil only if the getsockopt fails.
	public nonisolated let peerPID: Int32?
	private var nextID = 1
	private var pending: [Int: PendingCall] = [:]
	private var eventSubscribers: [UUID: AsyncStream<VMEvent>.Continuation] = [:]
	private var closed = false
	// Fired once when the connection dies (EOF, write failure) — after pending calls fail.
	private let onDisconnect: @Sendable () -> Void

	// How long one write may go without progress before the connection counts as lost: a
	// peer that stopped reading must not hold this actor in write() (E17).
	public static let defaultSendTimeout: Duration = .seconds(10)

	public init(
		socketPath: String, sendTimeout: Duration = RPCConnection.defaultSendTimeout,
		onDisconnect: @escaping @Sendable () -> Void = {}
	) throws {
		try self.init(
			socketPath: socketPath, sendTimeout: sendTimeout, readerHook: nil,
			onDisconnect: onDisconnect)
	}

	// The designated init. readerHook is a test seam: it runs on the reader thread after
	// each chunk the reader processed, so a test can park the reader between reads.
	init(
		socketPath: String, sendTimeout: Duration, readerHook: (@Sendable () -> Void)?,
		onDisconnect: @escaping @Sendable () -> Void
	) throws {
		self.onDisconnect = onDisconnect

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
		let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
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
		self.socket = SocketLifetime(fd: fd)
		// Bounded writes: no progress for sendTimeout fails the write with EAGAIN, and a
		// write to a peer that left fails with EPIPE instead of raising SIGPIPE.
		let (seconds, attoseconds) = sendTimeout.components
		var timeout = timeval(
			tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
		_ = setsockopt(
			fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var on: Int32 = 1
		_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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

	// MARK: - Calls

	public func call<P: Codable, R: Codable>(
		_ method: RPCMethod, _ params: P?, expecting: R.Type,
		deadline: Duration = RPCConnection.defaultCallDeadline
	) async throws -> R {
		let line = try await roundTrip(method, params, deadline: deadline)
		if let failure = try? MachmanWire.decoder().decode(RPCErrorReply.self, from: line) {
			throw failure.error.machmanError
		}
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
				let timer = Task { [weak self] in
					try? await Task.sleep(for: deadline)
					guard !Task.isCancelled else { return }
					await self?.expire(id: id, method: method, deadline: deadline)
				}
				pending[id] = PendingCall(continuation: continuation, timer: timer)
			}
		} onCancel: {
			Task { await self.abandon(id: id) }
		}
	}

	private func expire(id: Int, method: RPCMethod, deadline: Duration) {
		guard let call = pending.removeValue(forKey: id) else { return }
		call.continuation.resume(throwing: MachmanError(
			code: .timeout,
			message: "no reply to \(method.rawValue) after "
				+ "\(deadline.components.seconds)s — the serving process may be hung"))
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
		guard let peek = try? MachmanWire.decoder().decode(RPCPeek.self, from: line) else {
			return
		}
		if peek.isNotification, peek.method == RPCMethod.event.rawValue {
			if let call = try? MachmanWire.decoder().decode(RPCCall<VMEvent>.self, from: line),
				let event = call.params {
				for continuation in eventSubscribers.values {
					continuation.yield(event)
				}
			}
			return
		}
		if case .number(let id)? = peek.id, let call = pending.removeValue(forKey: id) {
			// The raw line goes back; the typed caller decodes result or error itself.
			// A reply whose id is no longer pending (timed out, cancelled) falls through
			// here and is dropped — abandoning a call must tolerate its late answer.
			call.timer.cancel()
			call.continuation.resume(returning: line)
		}
	}

	// MARK: - Events

	public func events() -> AsyncStream<VMEvent> {
		AsyncStream { continuation in
			let id = UUID()
			self.eventSubscribers[id] = continuation
			continuation.onTermination = { _ in
				Task { await self.removeSubscriber(id) }
			}
		}
	}

	private func removeSubscriber(_ id: UUID) {
		eventSubscribers[id] = nil
	}

	// MARK: - Teardown

	private func teardown() {
		guard !closed else { return }
		closed = true
		socket.shutDownByOwner()
		for call in pending.values {
			call.timer.cancel()
			call.continuation.resume(throwing: ConnectionError.disconnected)
		}
		pending.removeAll()
		for continuation in eventSubscribers.values {
			continuation.finish()
		}
		eventSubscribers.removeAll()
		onDisconnect()
	}

	public func disconnect() {
		teardown()
	}

	// A connection dropped without disconnect() still ends its reader and frees the socket.
	deinit {
		socket.shutDownByOwner()
	}

	// Test seams: the raw descriptor number, and whether it has been closed.
	nonisolated var fdForTesting: Int32 { socket.fd }
	nonisolated var socketClosedForTesting: Bool { socket.isClosed }
}
