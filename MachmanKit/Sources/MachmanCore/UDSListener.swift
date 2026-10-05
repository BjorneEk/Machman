//
//  UDSListener.swift
//  MachmanCore
//
//  Unix-domain-socket plumbing for the daemon: a listening socket with single-instance
//  enforcement, and a per-client connection doing newline framing over dispatch sources.
//

import Foundation
import MachmanAPI

// Public: hosts need to tell "someone else is already serving" — a benign race when a client
// auto-launches a daemon — apart from a genuine failure to bind.
public enum UDSError: Error, CustomStringConvertible, LocalizedError {
	case alreadyRunning(String)
	case pathTooLong(String)
	case systemError(String, Int32)

	// For the log: the path and the failing call.
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

	// For a person (the agent's “can’t start” alert, via MachmanError.userMessage): the
	// agent and the VM processes both serve sockets, so it names neither.
	public var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			return "Another copy is already serving its socket"
		case .pathTooLong:
			return "Its socket path is too long"
		case .systemError(let op, let err):
			let verb = op == "rename" ? "move" : "open"
			return "Couldn’t \(verb) its socket: \(String(cString: strerror(err)))"
		}
	}
}

final class UDSListener {
	private let fd: Int32
	private let bound: BoundSocket
	private let queue: DispatchQueue
	private let source: DispatchSourceRead
	private let keepAliveTimer: DispatchSourceTimer
	// Where the socket is served. Confined to `queue`: move(to:) renames it (Save as New VM)
	// while the keep-alive timer touches the current path.
	private var path: String
	private var reportedMissing = false

	// How often a served socket's timestamps are refreshed against the temp cleaner (see the
	// timer below) — the control sockets here and the serial data-plane sockets alike.
	static let defaultKeepAlive: DispatchTimeInterval = .seconds(3600)

	// onAccept is called on `queue` with each accepted (already non-blocking-cleared) fd.
	// keepAlive is how often the socket's timestamps are refreshed (see touch).
	init(
		path: String, queue: DispatchQueue, keepAlive: DispatchTimeInterval = defaultKeepAlive,
		onAccept: @escaping (Int32) -> Void
	) throws {
		self.path = path
		self.queue = queue
		_ = try Self.makeAddr(path)   // the sun_path ceiling, before touching any file

		// A leftover socket file: connect-probe it. A live daemon accepts (refuse to start);
		// a dead one refuses (stale file — remove and take over). Force quits and power losses
		// skip shutdown(), so a stale file is the normal case, not an exceptional one.
		if FileManager.default.fileExists(atPath: path) {
			if Self.isLive(path: path) {
				let holder = Self.holderPID(path: path).map { "pid \($0)" } ?? "an unknown process"
				MachmanLogger.log(.passiveWarning, "\(path) is already served by \(holder)")
				throw UDSError.alreadyRunning(path)
			}
			unlink(path)
		}

		let bound = try BoundSocket.listen(at: path)
		let fd = bound.fd
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		self.bound = bound
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

		// macOS's dirhelper deletes entries under /var/folders/…/T that went untouched for 3
		// days (CLEAN_FILES_OLDER_THAN_DAYS=3, run daily at 03:35), and connects never refresh
		// a socket's timestamps. A reaped vm-*.sock orphans its running vmhost; a reaped
		// machman.sock lets a second daemon bind. tmux defends its socket the same way.
		keepAliveTimer = DispatchSource.makeTimerSource(queue: queue)
		keepAliveTimer.schedule(deadline: .now() + keepAlive, repeating: keepAlive)
		keepAliveTimer.setEventHandler { [weak self] in
			guard let self else { return }
			let path = self.path
			guard !Self.touch(path), !self.reportedMissing,
				!FileManager.default.fileExists(atPath: path) else { return }
			// Never rebound: a second daemon may own the path by now.
			self.reportedMissing = true
			MachmanLogger.log(.passiveError,
				"\(path) was removed — new clients cannot reach this process until it restarts")
		}
		keepAliveTimer.resume()
	}

	// Serves the same bound socket at a new path (a vmhost whose VM was saved as a new VM,
	// E27). Probe-proven on Darwin: a listening socket follows a rename, accepted connections
	// keep delivering, and a dead leftover at the destination is replaced — a live one never
	// is. Synchronous on `queue`; accept handlers never wait on their caller, so it can't
	// deadlock.
	func move(to newPath: String) throws {
		_ = try Self.makeAddr(newPath)   // the sun_path ceiling, as at bind
		try queue.sync {
			guard newPath != path else { return }
			guard !Self.isLive(path: newPath) else { throw UDSError.alreadyRunning(newPath) }
			guard rename(path, newPath) == 0 else { throw UDSError.systemError("rename", errno) }
			path = newPath
			reportedMissing = false
		}
	}

	// The file goes BEFORE the descriptor closes, and only while it is still ours (E44). A
	// closed listener's file reads dead, and a successor probing in that gap (the agent's
	// takeover polls every 200 ms) unlinks it and binds its own — which an unlink after the
	// close then removed, leaving the new daemon serving a socket nobody could reach. Closing
	// never unlinks: the CURRENT path goes.
	func shutdown() {
		keepAliveTimer.cancel()
		source.cancel()
		queue.sync { bound.unlinkIfOurs(path) }
		close(fd)
	}

	// For tests that stand in for a forked child holding a copy of the listener.
	var descriptorForTesting: Int32 { fd }

	// For tests that need to simulate a kill: drop the socket but keep the file, exactly
	// what SIGKILL leaves behind. The source is cancelled first — a bare close() would free
	// the fd NUMBER under a still-armed source, which then watches whatever unrelated
	// socket a parallel test binds to that number (a real in-suite flake). A process another
	// test spawns holds a copy of every descriptor from fork until exec (FD_CLOEXEC does not
	// shorten that), so the closed socket can go on accepting for a moment and a probe right
	// after would read it live: this returns once a probe finds it dead, or after awaitDeath.
	func simulateKillForTesting(awaitDeath: Duration = .seconds(5)) {
		keepAliveTimer.cancel()
		source.cancel()
		close(fd)
		let served = queue.sync { path }
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: awaitDeath)
		while Self.isLive(path: served), clock.now < deadline {
			usleep(2_000)
		}
	}

	// Sets the socket's and its directory's access and modification times to now; false when
	// the socket itself could not be touched. Internal so the serial data-plane sockets, bound
	// outside this listener, can adopt it.
	@discardableResult
	static func touch(_ path: String) -> Bool {
		_ = utimes((path as NSString).deletingLastPathComponent, nil)
		return utimes(path, nil) == 0
	}

	// Whether something is actually accepting on this socket. The file existing means nothing:
	// only an orderly shutdown removes it, so anything killed leaves one behind. A refused
	// connect also means a full accept queue (see the backlog in init), which SOMAXCONN makes
	// unlikely but not impossible.
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

	// The pid of the process listening on this socket, nil when nothing accepts. A connect is
	// enough: LOCAL_PEERPID answers for the listener before it accepts (probe-checked), so
	// the probe never waits on the holder. It answers only while the connection stands: a
	// holder that accepts and hangs up before the ask leaves nothing to answer for (ENOTCONN,
	// nil). No server here does that — each keeps a connection until its peer leaves (Q17).
	static func holderPID(path: String) -> pid_t? {
		guard var addr = try? makeAddr(path) else { return nil }
		let probe = socket(AF_UNIX, SOCK_STREAM, 0)
		guard probe >= 0 else { return nil }
		defer { close(probe) }
		let connected = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard connected else { return nil }
		var pid: pid_t = 0
		var length = socklen_t(MemoryLayout<pid_t>.size)
		guard getsockopt(probe, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
		return pid
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

// A listening socket bound at a path, and the identity of the file it bound (E44). The control
// sockets (UDSListener) and the serial bridges share it, so both listen with the full backlog
// and only ever remove their own file.
struct BoundSocket {
	let fd: Int32
	private let device: dev_t
	private let inode: ino_t

	// Binds, listens and restricts the file to its owner; the caller cleared any dead leftover
	// at `path` first. A failure leaves neither a descriptor nor a file behind.
	static func listen(at path: String) throws -> BoundSocket {
		var addr = try UDSListener.makeAddr(path)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw UDSError.systemError("socket", errno) }
		let didBind = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		var info = stat()
		guard didBind, lstat(path, &info) == 0 else {
			let err = errno
			close(fd)
			throw UDSError.systemError("bind/listen", err)
		}
		let bound = BoundSocket(fd: fd, device: info.st_dev, inode: info.st_ino)
		// A full backlog, not just a dead socket, makes a UNIX-socket connect fail with
		// ECONNREFUSED, so a short one would let isLive(path:) misread a busy listener as
		// dead — and the router acts on that (unlink, route to the local engine), as does the
		// startup prune of serial sockets.
		guard Darwin.listen(fd, SOMAXCONN) == 0 else {
			let err = errno
			bound.unlinkIfOurs(path)
			close(fd)
			throw UDSError.systemError("bind/listen", err)
		}
		chmod(path, 0o600)   // same-user only; the socket IS the auth boundary
		return bound
	}

	// Removes the file at `path` if it is still the one this socket bound (a rename keeps it):
	// a successor may own the path by now. Called before the descriptor closes — while the
	// socket still listens a probe reads it live, so nothing replaces the file in between.
	func unlinkIfOurs(_ path: String) {
		var info = stat()
		guard lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode else { return }
		unlink(path)
	}
}

// One connected client: newline-framed reads via a dispatch source, serialized writes.
// Thread-safe to send from any context; onLine/onClose fire on the connection's queue.
//
// Writes are bounded (E17): a peer that stops reading is dropped, never buffered for. A write
// may go without progress for at most sendTimeout (SO_SNDTIMEO turns the stall into EAGAIN),
// and at most maxQueuedBytes may wait behind it. Either limit ends the connection, which the
// peer sees as EOF. Unbounded, one such client parked a GCD thread in write() for good and
// grew its queue with every event.
final class UDSConnection {
	let fd: Int32
	private let queue: DispatchQueue
	private let source: DispatchSourceRead
	private let sendTimeout: TimeInterval
	private let maxQueuedBytes: Int
	private var buffer = Data()
	private var closed = false
	// send() runs on any thread, the writes and the close on the queue: the byte count and
	// the descriptor's open state are shared under this lock.
	private let lock = NSLock()
	private var queuedBytes = 0
	private var overCap = false
	private var descriptorOpen = true
	var onLine: ((Data) -> Void)?
	var onClose: (() -> Void)?

	init(fd: Int32, sendTimeout: TimeInterval = 10, maxQueuedBytes: Int = 32 << 20) {
		self.fd = fd
		self.sendTimeout = sendTimeout
		self.maxQueuedBytes = maxQueuedBytes
		self.queue = DispatchQueue(label: "machman.uds.connection.\(fd)")
		// accept() on BSD inherits O_NONBLOCK from the listening socket; writes here must
		// block (large responses overflow the send buffer and would EAGAIN otherwise).
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
		// …but never for longer than sendTimeout without progress, and a write to a peer that
		// left fails with EPIPE instead of raising SIGPIPE in the whole process.
		var timeout = timeval(
			tv_sec: Int(sendTimeout),
			tv_usec: Int32((sendTimeout - sendTimeout.rounded(.down)) * 1_000_000))
		_ = setsockopt(
			fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var on: Int32 = 1
		_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler { [weak self] in
			self?.readAvailable()
		}
		// The descriptor is captured by value: it must close even when the connection object
		// is already gone (a weak-self guard leaked it then).
		source.setCancelHandler { [weak self, fd] in
			guard let self else {
				close(fd)
				return
			}
			self.lock.withLock {
				self.descriptorOpen = false
				close(fd)
			}
			self.onClose?()
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

	// Serialized on the connection queue; whole-message writes. A write that fails — the
	// peer left, or made no room for sendTimeout — ends the connection.
	func send(_ data: Data) {
		let size = data.count + 1
		lock.lock()
		guard !overCap else {
			lock.unlock()
			return
		}
		guard queuedBytes + size <= maxQueuedBytes else {
			overCap = true
			let queued = queuedBytes
			lock.unlock()
			MachmanLogger.log(.passiveWarning,
				"dropping a client that stopped reading (\(queued) bytes queued)")
			abort()
			return
		}
		queuedBytes += size
		lock.unlock()
		queue.async { [weak self] in
			guard let self = self else { return }
			defer { self.lock.withLock { self.queuedBytes -= size } }
			guard !self.closed else { return }
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
						// SO_SNDTIMEO expired: the peer took no bytes for the whole timeout.
						MachmanLogger.log(.passiveWarning,
							"dropping a client that stopped reading (no write progress for "
								+ "\(self.sendTimeout) s)")
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

	// Over the byte cap: a write is blocked on this peer, and the queue's shutdown would
	// only run after it times out. Shutting the socket down wakes that write with EPIPE now.
	// Never on a closed descriptor — its number may already belong to another socket.
	private func abort() {
		lock.withLock {
			if descriptorOpen {
				_ = Darwin.shutdown(fd, SHUT_RDWR)
			}
		}
		shutdown()
	}

	private func shutdownLocked() {
		guard !closed else { return }
		closed = true
		source.cancel()
	}
}
