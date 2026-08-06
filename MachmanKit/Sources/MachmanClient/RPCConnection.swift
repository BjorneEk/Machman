//
//  RPCConnection.swift
//  MachmanClient
//
//  One JSON-RPC connection to the daemon's unix socket: id-matched request/response plus
//  fan-out of "event" notifications. A dedicated reader thread feeds the actor; everything
//  else is actor-isolated.
//

import Foundation
import MachmanAPI

public actor RPCConnection {
	public enum ConnectionError: Error, CustomStringConvertible {
		case connectFailed(String, Int32)
		case disconnected

		public var description: String {
			switch self {
			case .connectFailed(let path, let err):
				return "cannot reach machmand at \(path): \(String(cString: strerror(err)))"
			case .disconnected:
				return "the daemon connection was lost"
			}
		}
	}

	private let fd: Int32
	private var nextID = 1
	private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
	private var eventSubscribers: [UUID: AsyncStream<VMEvent>.Continuation] = [:]
	private var closed = false
	// Fired once when the connection dies (EOF, write failure) — after pending calls fail.
	private let onDisconnect: @Sendable () -> Void

	public init(socketPath: String, onDisconnect: @escaping @Sendable () -> Void = {}) throws {
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
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
		self.fd = fd

		// Reader thread feeds an ordered line stream; a single task drains it into the actor,
		// preserving on-wire order for events and responses alike.
		let readFD = fd
		let (lines, feed) = AsyncStream<Data>.makeStream()
		Thread.detachNewThread {
			var buffer = Data()
			var chunk = [UInt8](repeating: 0, count: 64 * 1024)
			while true {
				let n = read(readFD, &chunk, chunk.count)
				if n <= 0 { break }
				buffer.append(contentsOf: chunk[0..<n])
				while let newline = buffer.firstIndex(of: 0x0A) {
					let line = buffer.subdata(in: buffer.startIndex..<newline)
					buffer.removeSubrange(buffer.startIndex...newline)
					if !line.isEmpty {
						feed.yield(line)
					}
				}
			}
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
		_ method: RPCMethod, _ params: P?, expecting: R.Type
	) async throws -> R {
		let line = try await roundTrip(method, params)
		if let failure = try? MachmanWire.decoder().decode(RPCErrorReply.self, from: line) {
			throw failure.error.machmanError
		}
		return try MachmanWire.decoder().decode(RPCResult<R>.self, from: line).result
	}

	private func roundTrip<P: Codable>(_ method: RPCMethod, _ params: P?) async throws -> Data {
		guard !closed else { throw ConnectionError.disconnected }
		let id = nextID
		nextID += 1
		let call = RPCCall(id: .number(id), method: method.rawValue, params: params)
		let data = try MachmanWire.encoder().encode(call)
		guard writeLine(data) else {
			teardown()
			throw ConnectionError.disconnected
		}
		return try await withCheckedThrowingContinuation { continuation in
			pending[id] = continuation
		}
	}

	private func writeLine(_ data: Data) -> Bool {
		var payload = data
		payload.append(0x0A)
		return payload.withUnsafeBytes { raw -> Bool in
			var offset = 0
			while offset < raw.count {
				let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
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
		if case .number(let id)? = peek.id, let continuation = pending.removeValue(forKey: id) {
			// The raw line goes back; the typed caller decodes result or error itself.
			continuation.resume(returning: line)
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
		close(fd)
		for continuation in pending.values {
			continuation.resume(throwing: ConnectionError.disconnected)
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
}
