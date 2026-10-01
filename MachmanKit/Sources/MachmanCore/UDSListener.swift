//
//  UDSListener.swift
//  MachmanCore
//
//  Unix-domain-socket plumbing for the daemon: a listening socket with single-instance
//  enforcement, and a per-client connection doing newline framing over dispatch sources.
//

import Foundation

// Public: hosts need to tell "someone else is already serving" — a benign race when a client
// auto-launches a daemon — apart from a genuine failure to bind.
public enum UDSError: Error, CustomStringConvertible {
	case alreadyRunning(String)
	case pathTooLong(String)
	case systemError(String, Int32)

	public var description: String {
		switch self {
		case .alreadyRunning(let path):
			return "another daemon is already serving \(path)"
		case .pathTooLong(let path):
			return "socket path too long for sockaddr_un: \(path)"
		case .systemError(let op, let err):
			return "\(op) failed: \(String(cString: strerror(err)))"
		}
	}
}

final class UDSListener {
	private let fd: Int32
	private let source: DispatchSourceRead
	private let path: String

	// onAccept is called on `queue` with each accepted (already non-blocking-cleared) fd.
	init(path: String, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) throws {
		self.path = path
		var addr = try Self.makeAddr(path)

		// A leftover socket file: connect-probe it. A live daemon accepts (refuse to start);
		// a dead one refuses (stale file — remove and take over). Force quits and power losses
		// skip shutdown(), so a stale file is the normal case, not an exceptional one.
		if FileManager.default.fileExists(atPath: path) {
			if Self.isLive(path: path) {
				throw UDSError.alreadyRunning(path)
			}
			unlink(path)
		}

		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw UDSError.systemError("socket", errno) }
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, 8) == 0 else {
			let err = errno
			close(fd)
			throw UDSError.systemError("bind/listen", err)
		}
		chmod(path, 0o600)   // same-user only; the socket IS the auth boundary
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		self.fd = fd

		source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler {
			while true {
				let client = accept(fd, nil, nil)
				if client < 0 { break }   // EWOULDBLOCK: drained
				onAccept(client)
			}
		}
		source.resume()
	}

	func shutdown() {
		source.cancel()
		close(fd)
		unlink(path)
	}

	// For tests that need to simulate a kill: drop the socket but keep the file, exactly
	// what SIGKILL leaves behind. The source is cancelled first — a bare close() would free
	// the fd NUMBER under a still-armed source, which then watches whatever unrelated
	// socket a parallel test binds to that number (a real in-suite flake).
	func simulateKillForTesting() {
		source.cancel()
		close(fd)
	}

	// Whether something is actually accepting on this socket. The file existing means nothing:
	// only an orderly shutdown removes it, so anything killed leaves one behind.
	static func isLive(path: String) -> Bool {
		guard FileManager.default.fileExists(atPath: path) else { return false }
		guard var addr = try? makeAddr(path) else { return false }
		let probe = socket(AF_UNIX, SOCK_STREAM, 0)
		guard probe >= 0 else { return false }
		defer { close(probe) }
		return withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
	}

	static func makeAddr(_ path: String) throws -> sockaddr_un {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
		guard path.utf8.count <= maxLen else { throw UDSError.pathTooLong(path) }
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
				_ = path.withCString { strlcpy(dst, $0, maxLen + 1) }
			}
		}
		return addr
	}
}

// One connected client: newline-framed reads via a dispatch source, serialized writes.
// Thread-safe to send from any context; onLine/onClose fire on the connection's queue.
final class UDSConnection {
	let fd: Int32
	private let queue: DispatchQueue
	private let source: DispatchSourceRead
	private var buffer = Data()
	private var closed = false
	var onLine: ((Data) -> Void)?
	var onClose: (() -> Void)?

	init(fd: Int32) {
		self.fd = fd
		self.queue = DispatchQueue(label: "machman.uds.connection.\(fd)")
		// accept() on BSD inherits O_NONBLOCK from the listening socket; writes here must
		// block (large responses overflow the send buffer and would EAGAIN otherwise).
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
		source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler { [weak self] in
			self?.readAvailable()
		}
		// The descriptor is captured by value: it must close even when the connection object
		// is already gone (a weak-self guard leaked it then).
		source.setCancelHandler { [weak self, fd] in
			close(fd)
			self?.onClose?()
		}
	}

	func start() {
		source.resume()
	}

	private func readAvailable() {
		var chunk = [UInt8](repeating: 0, count: 64 * 1024)
		let n = read(fd, &chunk, chunk.count)
		if n <= 0 {
			shutdown()
			return
		}
		buffer.append(contentsOf: chunk[0..<n])
		while let newline = buffer.firstIndex(of: 0x0A) {
			let line = buffer.subdata(in: buffer.startIndex..<newline)
			buffer.removeSubrange(buffer.startIndex...newline)
			if !line.isEmpty {
				onLine?(line)
			}
		}
	}

	// Serialized on the connection queue; whole-message write with EPIPE handling.
	func send(_ data: Data) {
		queue.async { [weak self] in
			guard let self = self, !self.closed else { return }
			var payload = data
			payload.append(0x0A)
			let ok = payload.withUnsafeBytes { raw -> Bool in
				var offset = 0
				while offset < raw.count {
					let n = write(self.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
					if n > 0 {
						offset += n
						continue
					}
					if errno == EINTR {
						continue
					}
					if errno == EAGAIN {
						// Shouldn't happen on a blocking fd; wait out a full buffer anyway.
						usleep(2000)
						continue
					}
					return false
				}
				return true
			}
			if !ok {
				self.shutdownLocked()
			}
		}
	}

	// Strong capture on purpose: the server's stop() drops its last reference right after
	// this call, and the source must still be cancelled (closing the descriptor) first.
	func shutdown() {
		queue.async {
			self.shutdownLocked()
		}
	}

	private func shutdownLocked() {
		guard !closed else { return }
		closed = true
		source.cancel()
	}
}
