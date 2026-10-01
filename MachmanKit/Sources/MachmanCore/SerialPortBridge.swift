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
//  the guest). SIGPIPE is ignored process-wide (a client that vanishes mid-write must not kill
//  the vmhost).
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
	private var drainSource: DispatchSourceRead?
	private var stopped = false
	// A reset-on-boot log is truncated by the run's FIRST open only; a retune appends (E25).
	private var logOpenedThisRun = false

	private static let replayCap = 256 * 1024

	private static let ignoreSIGPIPE: Void = {
		signal(SIGPIPE, SIG_IGN)
	}()

	init(
		kind: SerialPortKind, index: Int, socketPath: String, logURL: URL,
		logConfig: SerialLogConfig, toGuest: FileHandle, fromGuest: FileHandle
	) {
		self.kind = kind
		self.index = index
		self.socketPath = socketPath
		self.logURL = logURL
		self.logConfig = logConfig
		self.toGuest = toGuest
		self.fromGuest = fromGuest
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
		installDrain()
		queue.async { [weak self] in
			self?.openLog()
		}
		do {
			try bindSocket()
			installAccept()
		} catch {
			MachmanLogger.log(
				.passiveWarning,
				"serial \(kind.rawValue)\(index): \(error.localizedDescription) — remote attach "
					+ "disabled, logging still active")
		}
	}

	func stop() {
		queue.async { [weak self] in
			guard let self = self, !self.stopped else { return }
			self.stopped = true
			self.drainSource?.cancel()
			self.acceptSource?.cancel()
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
				self.ring.removeFirst(self.ring.count - Self.replayCap)
			}
			for fd in self.clients.keys { self.write(fd, data) }
		}
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
				self.toGuest.write(Data(buf[0..<n]))
			} else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
				self.removeClient(fd)
			}
		}
		source.setCancelHandler { close(fd) }
		clients[fd] = source
		source.resume()
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

	private func bridgeError(_ what: String) -> MachmanError {
		MachmanError(
			code: .ioFailure,
			message: "serial bridge \(kind.rawValue)\(index) \(what): "
				+ String(cString: strerror(errno)))
	}
}
