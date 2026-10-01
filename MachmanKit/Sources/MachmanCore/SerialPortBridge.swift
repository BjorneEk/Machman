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
//  per-client reads are DispatchSources targeting `queue`. Client writes are non-blocking and
//  best-effort (a slow client drops output rather than stalling the shared drain — and with it
//  the guest). Guest input is non-blocking too: what the guest pipe won't take waits in a
//  bounded buffer, and a guest that reads nothing loses input rather than freezing the drain.
//  SIGPIPE is ignored process-wide (a client that vanishes mid-write must not kill the vmhost),
//  and a closed guest end (EPIPE while VZ tears down) ends input instead of raising.
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
	private var clients: [Int32: DispatchSourceRead] = [:]
	private var warnedDrop: Set<Int32> = []
	private var listenerFD: Int32 = -1
	private var acceptSource: DispatchSourceRead?
	// The socket's timestamps, refreshed like the control sockets' (E30): the temp cleaner
	// reaps entries untouched for three days, and a console socket then can't be attached.
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
	private var warnedInputDrop = false

	private static let replayCap = 256 * 1024
	private static let guestInputCap = 64 * 1024

	private static let ignoreSIGPIPE: Void = {
		signal(SIGPIPE, SIG_IGN)
	}()

	init(
		kind: SerialPortKind, index: Int, socketPath: String, logURL: URL,
		logConfig: SerialLogConfig, toGuest: FileHandle, fromGuest: FileHandle,
		keepAlive: DispatchTimeInterval = UDSListener.defaultKeepAlive
	) {
		self.kind = kind
		self.index = index
		self.socketPath = socketPath
		self.logURL = logURL
		self.logConfig = logConfig
		self.toGuest = toGuest
		self.fromGuest = fromGuest
		self.keepAlive = keepAlive
	}

	// The on-disk log path when logging is enabled (nil when disabled or not yet started).
	func currentLogPath() -> String? {
		queue.sync { log != nil ? logURL.path : nil }
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
			self.drainSource?.cancel()
			self.guestInputSource?.cancel()
			self.guestInputSource = nil
			self.guestInput.removeAll()
			self.acceptSource?.cancel()
			self.keepAliveTimer?.cancel()
			for (_, source) in self.clients { source.cancel() }
			self.clients.removeAll()
			try? self.log?.close()
			self.log = nil
			if self.listenerFD >= 0 { close(self.listenerFD); self.listenerFD = -1 }
			unlink(self.socketPath)
		}
	}

	// Live change of file logging (vm.serial.setLogging while running).
	func retune(_ config: SerialLogConfig) {
		queue.async { [weak self] in
			guard let self = self, !self.stopped else { return }
			self.logConfig = config
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
			self.appendToLog(data)
			self.ring.append(data)
			if self.ring.count > Self.replayCap {
				self.ring.dropHead(self.ring.count - Self.replayCap, live: Self.replayCap)
			}
			for fd in self.clients.keys { self.write(fd, data) }
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
		log = FileHandle(forWritingAtPath: logURL.path)
		let end = (try? log?.seekToEnd()) ?? 0
		logBytes = end
	}

	private func appendToLog(_ data: Data) {
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
			try? log.close()
			let full = (try? Data(contentsOf: logURL)) ?? Data()
			let tail = Data(full.suffix(Int(clamping: cap)))
			try? tail.write(to: logURL)
			self.log = FileHandle(forWritingAtPath: logURL.path)
			try? self.log?.seekToEnd()
			logBytes = UInt64(tail.count)
		}
	}

	// MARK: - Clients

	// Best-effort, non-blocking: a client that can't keep up drops output rather than stalling
	// the drain. Runs on `queue`, so no locking around `warnedDrop`.
	private func write(_ fd: Int32, _ data: Data) {
		let sent = data.withUnsafeBytes { raw -> Int in
			guard let base = raw.baseAddress else { return data.count }
			var off = 0
			while off < data.count {
				let n = Foundation.write(fd, base + off, data.count - off)
				if n > 0 { off += n; continue }
				if n < 0 && errno == EINTR { continue }
				break   // EAGAIN or error: drop the remainder
			}
			return off
		}
		if sent < data.count, warnedDrop.insert(fd).inserted {
			MachmanLogger.log(.log, "serial \(kind.rawValue)\(index): slow client, dropping output")
		}
	}

	private func addClient(_ fd: Int32) {
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		write(fd, ring)   // replay recent context to the new arrival
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
		source.setCancelHandler { close(fd) }
		clients[fd] = source
		source.resume()
	}

	// MARK: - Guest input

	// Client input -> guest without ever blocking `queue`: write what the pipe takes now, keep
	// the rest (in order) for the write source, and past guestInputCap drop new input — a guest
	// that reads nothing must not freeze the drain.
	private func sendToGuest(_ data: Data) {
		guard !stopped, !guestInputClosed else { return }
		var pending = data
		if guestInput.isEmpty {
			guard let sent = writeToGuest(data) else { return }
			pending = data.dropFirst(sent)
		}
		guard !pending.isEmpty else { return }
		let room = max(0, Self.guestInputCap - guestInput.count)
		if pending.count > room, !warnedInputDrop {
			warnedInputDrop = true
			MachmanLogger.log(
				.log, "serial \(kind.rawValue)\(index): guest not reading input, dropping it")
		}
		guestInput.append(pending.prefix(room))
		if !guestInput.isEmpty { armGuestInput() }
	}

	// Non-blocking write of as much as the pipe takes: the byte count, or nil once the guest
	// end is gone (EPIPE) or the write failed, which closes input for the rest of the run.
	private func writeToGuest(_ data: Data) -> Int? {
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
		guard failure == 0 else {
			closeGuestInput(failure)
			return nil
		}
		return sent
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
		guard let sent = writeToGuest(guestInput) else { return }
		guestInput.dropHead(sent, live: Self.guestInputCap)
		if guestInput.isEmpty {
			guestInputSource?.cancel()
			guestInputSource = nil
			warnedInputDrop = false
		}
	}

	private func closeGuestInput(_ error: Int32) {
		guestInputClosed = true
		guestInput.removeAll()
		guestInputSource?.cancel()
		guestInputSource = nil
		MachmanLogger.log(
			.log, "serial \(kind.rawValue)\(index): guest input closed ("
				+ String(cString: strerror(error)) + "), dropping input")
	}

	private func removeClient(_ fd: Int32) {
		guard let source = clients.removeValue(forKey: fd) else { return }
		warnedDrop.remove(fd)
		source.cancel()
	}

	// MARK: - Socket

	private func bindSocket() throws {
		unlink(socketPath)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw bridgeError("socket") }
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
			close(fd)
			throw bridgeError("socket path too long")
		}
		withUnsafeMutableBytes(of: &addr.sun_path) { raw in
			raw.copyBytes(from: Array(socketPath.utf8))
		}
		let bound = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
				bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard bound == 0 else { close(fd); throw bridgeError("bind") }
		chmod(socketPath, 0o600)
		guard listen(fd, 8) == 0 else { close(fd); throw bridgeError("listen") }
		listenerFD = fd
	}

	private func installAccept() {
		let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
		source.setEventHandler { [weak self] in
			guard let self = self, !self.stopped else { return }
			let fd = accept(self.listenerFD, nil, nil)
			if fd >= 0 { self.addClient(fd) }
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

	private func bridgeError(_ what: String) -> MachmanError {
		MachmanError(
			code: .ioFailure,
			message: "serial bridge \(kind.rawValue)\(index) \(what): "
				+ String(cString: strerror(errno)))
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
