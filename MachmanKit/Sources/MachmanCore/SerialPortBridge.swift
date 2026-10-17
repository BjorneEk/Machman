//
//  SerialPortBridge.swift
//  MachmanCore
//
//  One serial port's raw-byte data plane. The vmhost owns the host ends of a serial port's two
//  pipes; this bridge continuously drains guest output (an undrained VZ serial attachment stalls
//  the guest — measured), tees it to an optional log file and broadcasts it to every client
//  attached on a per-port unix socket, and writes client input back to the guest. Ported from the
//  socket-research 02-socket-bridge spike. One bridge per port.
//
//  All state runs on one serial queue, so there are no locks: the drain, the accept loop and the
//  per-client reads are DispatchSources targeting `queue`. A capped log's trim runs on a queue of
//  its own, holding only the log's handle until it hands it back (E67). Client writes are non-blocking: what
//  a client's socket won't take waits in a bounded per-client backlog (E58), and a client that
//  falls further behind is closed, to come back to the replay — never the shared drain, and
//  with it the guest, stalls on it. Guest input is non-blocking too: what the guest pipe won't
//  take waits in a bounded buffer, and a guest that reads nothing loses input rather than
//  freezing the drain.
//  SIGPIPE is ignored process-wide (a client that vanishes mid-write must not kill the vmhost),
//  and a closed guest end (EPIPE while VZ tears down) ends input instead of raising. Every byte
//  is counted (E58) and the counts logged when a client leaves and at stop, so a console that
//  seems to stop taking input can be told apart: input lost here, a guest that stopped reading
//  (input left waiting), or output a slow client never got.
//

import Foundation
import MachmanAPI

final class SerialPortBridge {
	let kind: SerialPortKind
	let index: Int
	let socketPath: String
	private let logURL: URL
	private let toGuest: FileHandle     // host writes here -> guest reads
	private let fromGuest: FileHandle   // guest writes -> host reads here

	private let queue = DispatchQueue(label: "com.gustaffranzen.Machman.serial-bridge")
	private var logConfig: SerialLogConfig
	private var log: FileHandle?
	private var logBytes: UInt64 = 0
	private var ring = Data()
	private var clients: [Int32: Client] = [:]
	private var listener: BoundSocket?
	private var acceptSource: DispatchSourceRead?
	// The socket's timestamps, refreshed like the control sockets' (E30): the temp cleaner
	// reaps entries untouched for three days, and a console socket then can't be attached. A
	// lab run's interval knob applies here too (Q23).
	private let keepAlive: DispatchTimeInterval
	private var keepAliveTimer: DispatchSourceTimer?
	private var reportedMissing = false
	private var drainSource: DispatchSourceRead?
	private var stopped = false
	// A reset-on-boot log is truncated by the run's FIRST open only; a retune appends (E25).
	private var logOpenedThisRun = false
	// Client input the guest pipe has not taken yet, flushed by `guestInputSource` as the
	// guest reads; bounded by guestInputCap. Closed for good on EPIPE (the guest end is gone).
	private var guestInput = Data()
	private var guestInputSource: DispatchSourceWrite?
	private var guestInputClosed = false
	// The "guest not reading input" warning says it once per paste burst (C25, E59): it
	// re-arms only after nothing has waited for the guest for a second — a guest that drains
	// the buffer in bursts mid-paste is not caught up.
	private var warnedInputDrop = false
	private var caughtUpSince: UInt64?
	private let clock: @Sendable () -> UInt64
	private static let inputWarningRearm: UInt64 = 1_000_000_000
	private var counts = Counters()
	// A capped log's trim runs on its own queue (E67): the log's handle is the trim's until it
	// ends, and the drain holds what the guest writes meanwhile — at most pendingLogCap; what
	// doesn't fit misses the log and is counted. A retune that lands meanwhile reopens after.
	private let trimQueue = DispatchQueue(
		label: "com.gustaffranzen.Machman.serial-log-trim", qos: .utility)
	private let trim: @Sendable (Int32, UInt64) throws -> Void
	private var trimming = false
	private var pendingLog = Data()
	private var pendingLogMissed: UInt64 = 0
	private var reopenAfterTrim = false
	private static let pendingLogCap = 1024 * 1024

	// What crossed the port this run (E58). Every typed byte is taken by the guest pipe,
	// waiting for it, or dropped (past the buffer, or the guest end gone).
	struct Counters: Equatable, Sendable {
		var typed: UInt64 = 0
		var taken: UInt64 = 0
		var waiting: UInt64 = 0
		var dropped: UInt64 = 0
		var dropWarnings = 0
		var output: UInt64 = 0

		// "serial console2 counts: typed 12, taken 12, waiting 0, dropped 0, output 4096", and
		// for a client that left "; client got 4096, lost 0".
		func line(port: String, client: ClientCounts? = nil) -> String {
			"serial \(port) counts: typed \(typed), taken \(taken), waiting \(waiting), "
				+ "dropped \(dropped), output \(output)"
				+ (client.map { "; client got \($0.sent), lost \($0.lost)" } ?? "")
		}
	}

	// One client's share of the output: what it was sent, and what it lost by not reading.
	struct ClientCounts: Equatable, Sendable {
		var sent: UInt64 = 0
		var lost: UInt64 = 0
	}

	// One attached terminal: its socket, the output the socket has not taken yet (flushed by
	// `writer` as the client reads), and its counts. The descriptor closes once no source
	// watches it any more (GCD's rule, E48): the reader and, while output waits, the writer.
	private final class Client {
		let fd: Int32
		var reader: DispatchSourceRead?
		var writer: DispatchSourceWrite?
		var backlog = Data()
		var counts = ClientCounts()
		private var watching = 0

		init(fd: Int32) { self.fd = fd }

		func watch(_ source: DispatchSourceProtocol) {
			watching += 1
			source.setCancelHandler { [self] in
				watching -= 1
				if watching == 0 { close(fd) }
			}
		}
	}

	private static let replayCap = 256 * 1024
	private static let guestInputCap = 64 * 1024
	// E58: how far one terminal may fall behind the guest's output before it is closed.
	private static let clientBacklogCap = 1024 * 1024

	private static let ignoreSIGPIPE: Void = {
		signal(SIGPIPE, SIG_IGN)
	}()

	init(
		kind: SerialPortKind, index: Int, socketPath: String, logURL: URL,
		logConfig: SerialLogConfig, toGuest: FileHandle, fromGuest: FileHandle,
		keepAlive: DispatchTimeInterval = MachmanServer.keepAlive(),
		clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
		trim: @escaping @Sendable (Int32, UInt64) throws -> Void = {
			try SerialPortBridge.trimLog(fd: $0, keeping: $1)
		}
	) {
		self.kind = kind
		self.index = index
		self.socketPath = socketPath
		self.logURL = logURL
		self.logConfig = logConfig
		self.toGuest = toGuest
		self.fromGuest = fromGuest
		self.keepAlive = keepAlive
		self.clock = clock
		self.trim = trim
	}

	// The on-disk log path when logging is enabled (nil when disabled or not yet started).
	func currentLogPath() -> String? {
		queue.sync { log != nil || trimming ? logURL.path : nil }
	}

	// MARK: - Lifecycle

	// Non-throwing on purpose: the drain is installed FIRST, so even if the socket can't be bound
	// (leaving the port unattachable) the guest's output is still drained and never stalls.
	func start() {
		_ = Self.ignoreSIGPIPE
		let inputFD = toGuest.fileDescriptor
		_ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
		installDrain()
		queue.async { [weak self] in
			self?.openLog()
		}
		do {
			try bindSocket()
			installAccept()
			installKeepAlive()
		} catch {
			MachmanLogger.log(
				.passiveWarning,
				"serial \(kind.rawValue)\(index): \(error.localizedDescription) — remote attach "
					+ "disabled, logging still active")
		}
	}

	// Captures self strongly: VMRuntime drops its bridges right after calling this, and the
	// cancels below must still run before the pipe handles close with the bridge.
	func stop() {
		queue.async { [self] in
			guard !self.stopped else { return }
			self.stopped = true
			// The socket goes first: a terminal that sees its connection end must not find a
			// bridge still serving and take it for one that closed it for falling behind.
			self.listener?.unlinkIfOurs(self.socketPath)
			MachmanLogger.log(.log, self.countsLine(client: nil))
			self.drainSource?.cancel()
			self.guestInputSource?.cancel()
			self.guestInputSource = nil
			self.guestInput.removeAll()
			self.acceptSource?.cancel()
			self.keepAliveTimer?.cancel()
			for client in self.clients.values { self.cancel(client) }
			self.clients.removeAll()
			try? self.log?.close()
			self.log = nil
			self.pendingLog.removeAll()   // a trim in flight closes its handle as it ends
			// The accept source's cancel handler removes the socket and closes it (E48).
			self.listener = nil
		}
	}

	// Live change of file logging (vm.serial.setLogging while running).
	func retune(_ config: SerialLogConfig) {
		queue.async { [weak self] in
			guard let self = self, !self.stopped else { return }
			self.logConfig = config
			guard !self.trimming else {
				self.reopenAfterTrim = true
				return
			}
			try? self.log?.close()
			self.log = nil
			self.openLog()
		}
	}

	// MARK: - Guest output (the always-on drain)

	private func installDrain() {
		let source = DispatchSource.makeReadSource(
			fileDescriptor: fromGuest.fileDescriptor, queue: queue)
		source.setEventHandler { [weak self] in
			guard let self = self, !self.stopped else { return }
			var buf = [UInt8](repeating: 0, count: 16 * 1024)
			let n = read(self.fromGuest.fileDescriptor, &buf, buf.count)
			guard n > 0 else { return }
			let data = Data(buf[0..<n])
			self.counts.output += UInt64(n)
			self.appendToLog(data)
			self.ring.append(data)
			if self.ring.count > Self.replayCap {
				self.ring.dropHead(self.ring.count - Self.replayCap, live: Self.replayCap)
			}
			for client in self.clients.values { self.send(client, data) }
		}
		// The fd must outlive the source's registration: the cancel handler holds the handle.
		source.setCancelHandler { [fromGuest] in _ = fromGuest }
		drainSource = source
		source.resume()
	}

	// MARK: - Log tee

	private func openLog() {
		switch logConfig.mode {
		case .disabled:
			log = nil
			return
		case .resetOnBoot where !logOpenedThisRun:
			// The run's first open drops the previous boot's output.
			FileManager.default.createFile(atPath: logURL.path, contents: nil)
		case .resetOnBoot, .continuous:
			// Continuous, or a retune reopening this run's log: append, never truncate.
			if !FileManager.default.fileExists(atPath: logURL.path) {
				FileManager.default.createFile(atPath: logURL.path, contents: nil)
			}
		}
		logOpenedThisRun = true
		// Read-write: the trim reads the tail back through the same file (E67).
		log = FileHandle(forUpdatingAtPath: logURL.path)
		let end = (try? log?.seekToEnd()) ?? 0
		logBytes = end
	}

	private func appendToLog(_ data: Data) {
		if trimming {
			let kept = data.prefix(max(0, Self.pendingLogCap - pendingLog.count))
			pendingLog.append(kept)
			pendingLogMissed += UInt64(data.count - kept.count)
			return
		}
		guard let log = log else { return }
		do {
			try log.write(contentsOf: data)
			logBytes += UInt64(data.count)
		} catch {
			return
		}
		// Bounded logs grow to 2x the cap, then get trimmed back to the last `cap` bytes — so the
		// occasional rewrite is amortized O(1) per byte while one clean file keeps the recent tail.
		// A cap whose double overflows (2^63 and up — a script's "no cap") never trims.
		guard let cap = logConfig.maxBytes, cap > 0 else { return }
		let (threshold, overflow) = cap.multipliedReportingOverflow(by: 2)
		if !overflow, logBytes > threshold {
			startTrim(log, keeping: cap)
		}
	}

	// The trim reads up to 2x the cap (2 GiB at the largest) and writes it back: never on this
	// queue, which also drains the guest — an undrained port stalls it — and never the whole
	// log in memory (E67).
	private func startTrim(_ handle: FileHandle, keeping cap: UInt64) {
		trimming = true
		log = nil
		let trim = self.trim
		trimQueue.async { [weak self] in
			var failure: Error?
			do {
				try trim(handle.fileDescriptor, cap)
			} catch {
				failure = error
			}
			guard let self else {
				try? handle.close()
				return
			}
			self.queue.async { self.finishTrim(handle, failure: failure) }
		}
	}

	private func finishTrim(_ handle: FileHandle, failure: Error?) {
		trimming = false
		guard !stopped else {
			try? handle.close()
			return
		}
		if let failure {
			MachmanLogger.log(.passiveWarning,
				"serial \(kind.rawValue)\(index): trimming its log failed: \(failure)")
		}
		if reopenAfterTrim {
			reopenAfterTrim = false
			try? handle.close()
			openLog()
		} else {
			log = handle
			logBytes = (try? handle.seekToEnd()) ?? 0
		}
		if pendingLogMissed > 0 {
			MachmanLogger.log(.log, "serial \(kind.rawValue)\(index): \(pendingLogMissed) bytes "
				+ "of output missed the log while it was trimmed")
			pendingLogMissed = 0
		}
		let held = pendingLog
		pendingLog = Data()
		if !held.isEmpty { appendToLog(held) }
	}

	// MARK: - Clients

	// Output to one client without ever blocking `queue`: what its socket takes now, the rest
	// (in order) for its write source — a terminal that stops reading must not stall the
	// drain. The socket alone holds about 16 KiB: a burst that came while a busy client wasn't
	// reading lost its tail, the echo a console session waited on among it (E58). A client
	// still clientBacklogCap behind is stuck (E58): it is closed rather than handed output with
	// a hole in it, and a terminal that comes back starts over from the replay.
	private func send(_ client: Client, _ data: Data) {
		var pending = data
		if client.backlog.isEmpty {
			let (sent, failed) = writeToClient(client.fd, data)
			client.counts.sent += UInt64(sent)
			pending = data.dropFirst(sent)
			if failed {
				// Gone: its reader's EOF removes it.
				client.counts.lost += UInt64(pending.count)
				return
			}
		}
		guard !pending.isEmpty else { return }
		guard client.backlog.count + pending.count <= Self.clientBacklogCap else {
			client.counts.lost += UInt64(client.backlog.count + pending.count)
			client.backlog.removeAll()
			MachmanLogger.log(.log, "serial \(kind.rawValue)\(index): a client fell "
				+ "\(Self.clientBacklogCap >> 20) MiB behind the guest's output, closing it")
			removeClient(client.fd)
			return
		}
		client.backlog.append(pending)
		armWriter(client)
	}

	// Non-blocking write of as much as the socket takes, and whether it failed for good.
	private func writeToClient(_ fd: Int32, _ data: Data) -> (sent: Int, failed: Bool) {
		var failed = false
		let sent = data.withUnsafeBytes { raw -> Int in
			guard let base = raw.baseAddress else { return 0 }
			var off = 0
			while off < data.count {
				let n = Foundation.write(fd, base + off, data.count - off)
				if n > 0 { off += n; continue }
				if n < 0 && errno == EINTR { continue }
				failed = n < 0 && errno != EAGAIN
				break   // EAGAIN: the socket is full — the rest waits for the write source
			}
			return off
		}
		return (sent, failed)
	}

	private func armWriter(_ client: Client) {
		guard client.writer == nil else { return }
		let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
		source.setEventHandler { [weak self, weak client] in
			guard let self, let client else { return }
			self.flush(client)
		}
		client.watch(source)
		client.writer = source
		source.resume()
	}

	private func flush(_ client: Client) {
		let (sent, failed) = writeToClient(client.fd, client.backlog)
		client.counts.sent += UInt64(sent)
		client.backlog.dropHead(sent, live: Self.clientBacklogCap)
		if failed {
			client.counts.lost += UInt64(client.backlog.count)
			client.backlog.removeAll()
		}
		if client.backlog.isEmpty {
			client.writer?.cancel()
			client.writer = nil
		}
	}

	private func addClient(_ fd: Int32) {
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		let client = Client(fd: fd)
		let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler { [weak self] in
			guard let self = self else { return }
			var buf = [UInt8](repeating: 0, count: 4096)
			let n = read(fd, &buf, buf.count)
			if n > 0 {
				self.sendToGuest(Data(buf[0..<n]))
			} else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
				self.removeClient(fd)
			}
		}
		client.watch(source)
		client.reader = source
		clients[fd] = client
		send(client, ring)   // replay recent context to the new arrival
		source.resume()
	}

	// MARK: - Guest input

	// Client input -> guest without ever blocking `queue`: write what the pipe takes now, keep
	// the rest (in order) for the write source, and past guestInputCap drop new input — a guest
	// that reads nothing must not freeze the drain.
	private func sendToGuest(_ data: Data) {
		guard !stopped else { return }
		counts.typed += UInt64(data.count)
		guard !guestInputClosed else {
			counts.dropped += UInt64(data.count)
			return
		}
		var pending = data
		if guestInput.isEmpty {
			let (sent, failure) = writeToGuest(data)
			pending = data.dropFirst(sent)
			if failure != 0 {
				counts.dropped += UInt64(pending.count)
				closeGuestInput(failure)
				return
			}
		}
		guard !pending.isEmpty else { return }
		if guestInput.isEmpty {
			// A backlog starts: a guest that kept up for a second may be warned about again.
			if warnedInputDrop, let since = caughtUpSince,
				clock() &- since >= Self.inputWarningRearm {
				warnedInputDrop = false
			}
			caughtUpSince = nil
		}
		let room = max(0, Self.guestInputCap - guestInput.count)
		if pending.count > room, !warnedInputDrop {
			warnedInputDrop = true
			counts.dropWarnings += 1
			MachmanLogger.log(
				.log, "serial \(kind.rawValue)\(index): guest not reading input, dropping it")
		}
		let kept = pending.prefix(room)
		counts.dropped += UInt64(pending.count - kept.count)
		guestInput.append(kept)
		if !guestInput.isEmpty { armGuestInput() }
	}

	// Non-blocking write of as much as the pipe takes, counted as taken, and the errno that
	// stopped it: a guest end that is gone (EPIPE) or a failed write is the caller's to close
	// input on for the rest of the run.
	private func writeToGuest(_ data: Data) -> (sent: Int, failure: Int32) {
		let fd = toGuest.fileDescriptor
		var failure: Int32 = 0
		let sent = data.withUnsafeBytes { raw -> Int in
			guard let base = raw.baseAddress else { return 0 }
			var off = 0
			while off < data.count {
				let n = Foundation.write(fd, base + off, data.count - off)
				if n > 0 { off += n; continue }
				if n < 0 && errno == EINTR { continue }
				if n < 0 && errno != EAGAIN { failure = errno }
				break   // EAGAIN: the pipe is full — the rest waits for the write source
			}
			return off
		}
		counts.taken += UInt64(sent)
		return (sent, failure)
	}

	private func armGuestInput() {
		guard guestInputSource == nil else { return }
		let source = DispatchSource.makeWriteSource(
			fileDescriptor: toGuest.fileDescriptor, queue: queue)
		source.setEventHandler { [weak self] in self?.flushGuestInput() }
		source.setCancelHandler { [toGuest] in _ = toGuest }
		guestInputSource = source
		source.resume()
	}

	private func flushGuestInput() {
		guard !stopped, !guestInputClosed else { return }
		let (sent, failure) = writeToGuest(guestInput)
		guestInput.dropHead(sent, live: Self.guestInputCap)
		if failure != 0 {
			closeGuestInput(failure)
			return
		}
		if guestInput.isEmpty {
			guestInputSource?.cancel()
			guestInputSource = nil
			caughtUpSince = clock()
		}
	}

	private func closeGuestInput(_ error: Int32) {
		guestInputClosed = true
		counts.dropped += UInt64(guestInput.count)
		guestInput.removeAll()
		guestInputSource?.cancel()
		guestInputSource = nil
		MachmanLogger.log(
			.log, "serial \(kind.rawValue)\(index): guest input closed ("
				+ String(cString: strerror(error)) + "), dropping input")
	}

	private func removeClient(_ fd: Int32) {
		guard let client = clients.removeValue(forKey: fd) else { return }
		MachmanLogger.log(.log, countsLine(client: client.counts))
		cancel(client)
	}

	private func cancel(_ client: Client) {
		client.writer?.cancel()
		client.writer = nil
		client.reader?.cancel()
		client.reader = nil
	}

	private func countsLine(client: ClientCounts?) -> String {
		var now = counts
		now.waiting = UInt64(guestInput.count)
		return now.line(port: "\(kind.rawValue)\(index)", client: client)
	}

	// MARK: - Socket

	private func bindSocket() throws {
		// Never take a live socket: whoever answers there serves another run's port, and
		// unlinking it would cross-wire that run's terminals (E27). A dead leftover goes.
		guard !UDSListener.isLive(path: socketPath) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "serial bridge \(kind.rawValue)\(index): \(socketPath) is in use")
		}
		unlink(socketPath)
		// The control sockets' binding (E44): the sun_path ceiling, the full backlog (a short
		// one let the startup prune's isLive read a busy bridge as dead), the bound file's
		// identity for stop.
		do {
			listener = try BoundSocket.listen(at: socketPath)
		} catch {
			throw MachmanError(
				code: .ioFailure, message: "serial bridge \(kind.rawValue)\(index): \(error)")
		}
	}

	private func installAccept() {
		guard let listener else { return }
		let listenerFD = listener.fd
		let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
		source.setEventHandler { [weak self] in
			guard let self = self, !self.stopped else { return }
			let fd = accept(listenerFD, nil, nil)
			if fd >= 0 { self.addClient(fd) }
		}
		// The descriptor closes once nothing watches it (GCD's rule, E48), its file first and
		// only the one this bridge bound: the path may be another run's (E27), or a
		// successor's by now (E44).
		source.setCancelHandler { [socketPath] in
			listener.unlinkIfOurs(socketPath)
			close(listenerFD)
		}
		acceptSource = source
		source.resume()
	}

	// Never rebinds a removed socket, like UDSListener: says so once instead.
	private func installKeepAlive() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now() + keepAlive, repeating: keepAlive)
		timer.setEventHandler { [weak self] in
			guard let self, !self.stopped, !UDSListener.touch(self.socketPath),
				!self.reportedMissing,
				!FileManager.default.fileExists(atPath: self.socketPath) else { return }
			self.reportedMissing = true
			MachmanLogger.log(.passiveWarning,
				"\(self.socketPath) was removed — terminals cannot attach to "
					+ "\(self.kind.rawValue)\(self.index) until the VM restarts")
		}
		keepAliveTimer = timer
		timer.resume()
	}

	// What the two head-trimmed buffers' storage spans (E31) — a test seam.
	var retainedForTesting: (ring: Int, guestInput: Int) {
		queue.sync { (ring.endIndex, guestInput.endIndex) }
	}

	// What crossed the port so far, and each attached client's share (E58) — a test seam.
	var countsForTesting: (port: Counters, clients: [ClientCounts]) {
		queue.sync {
			var now = counts
			now.waiting = UInt64(guestInput.count)
			return (now, clients.values.map(\.counts))
		}
	}
}

extension Data {
	// Drops the first `count` bytes and keeps the storage bounded (E31). removeFirst only
	// advances startIndex: the storage keeps every byte ever appended, for the VM's whole
	// lifetime. Once the dropped head passes twice `live` (the most the buffer holds), the
	// tail moves into fresh storage — one copy per 2×live bytes dropped.
	mutating func dropHead(_ count: Int, live: Int) {
		removeFirst(count)
		if startIndex > 2 * live { self = Data(self) }
	}
}
