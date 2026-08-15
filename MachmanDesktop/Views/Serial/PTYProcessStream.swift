//
//  PTYProcessStream.swift
//  MachmanDesktop
//
//  A TerminalByteStream backed by a local process on a PTY — the transport behind the
//  ephemeral SSH tabs. Owns the PTY pair, mirrors SerialTerminalConnection's read-source
//  + bounded-transcript shape, forwards window sizes via TIOCSWINSZ, and reports child
//  exit as onClose (exactly once, whether the process quit or the fd hit EOF first).
//

import Foundation

final class PTYProcessStream: TerminalByteStream {
	private let executablePath: String
	private let arguments: [String]
	private let environmentOverrides: [String: String]
	private var process: Process?
	private var parentFD: Int32 = -1
	private var readSource: DispatchSourceRead?
	private let transcriptLock = NSLock()
	private var transcript = Data()
	private static let transcriptCap = 8 << 20

	var onData: ((Data) -> Void)?
	var onClose: (() -> Void)?

	// environmentOverrides ride on top of the app's environment — a GUI app carries no
	// TERM, and without one ssh advertises TERM=dumb to the guest.
	init(
		executablePath: String, arguments: [String],
		environmentOverrides: [String: String] = [:]
	) {
		self.executablePath = executablePath
		self.arguments = arguments
		self.environmentOverrides = environmentOverrides
	}

	func connect() -> Bool {
		var parent: Int32 = -1
		var child: Int32 = -1
		guard openpty(&parent, &child, nil, nil, nil) == 0 else { return false }
		let childHandle = FileHandle(fileDescriptor: child, closeOnDealloc: false)
		let p = Process()
		p.executableURL = URL(fileURLWithPath: executablePath)
		p.arguments = arguments
		if !environmentOverrides.isEmpty {
			p.environment = ProcessInfo.processInfo.environment
				.merging(environmentOverrides) { _, override in override }
		}
		p.standardInput = childHandle
		p.standardOutput = childHandle
		p.standardError = childHandle
		p.terminationHandler = { [weak self] _ in
			DispatchQueue.main.async { self?.finish() }
		}
		do {
			try p.run()
		} catch {
			close(parent)
			close(child)
			return false
		}
		close(child)   // the child's end lives inside the spawned process now
		process = p
		parentFD = parent
		let source = DispatchSource.makeReadSource(fileDescriptor: parent, queue: .global())
		source.setEventHandler { [weak self] in
			guard let self = self else { return }
			var buf = [UInt8](repeating: 0, count: 8192)
			let n = read(self.parentFD, &buf, buf.count)
			if n > 0 {
				let data = Data(buf[0..<n])
				self.appendTranscript(data)
				DispatchQueue.main.async { self.onData?(data) }
			} else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
				DispatchQueue.main.async { self.finish() }
			}
		}
		readSource = source
		source.resume()
		return true
	}

	// The single close path (main queue): first caller wins — termination handler and
	// fd EOF both funnel here.
	private func finish() {
		guard process != nil else { return }
		stop()
		onClose?()
	}

	func send(_ data: Data) {
		guard parentFD >= 0 else { return }
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var off = 0
			while off < data.count {
				let n = write(parentFD, base + off, data.count - off)
				if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
			}
		}
	}

	func stop() {
		readSource?.cancel()
		readSource = nil
		if parentFD >= 0 { close(parentFD); parentFD = -1 }
		if let p = process {
			process = nil
			p.terminationHandler = nil   // no late callback after an explicit stop
			if p.isRunning { p.terminate() }
		}
	}

	func setWindowSize(cols: Int, rows: Int) {
		guard parentFD >= 0, cols > 0, rows > 0 else { return }
		var size = winsize(
			ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
			ws_xpixel: 0, ws_ypixel: 0)
		_ = ioctl(parentFD, TIOCSWINSZ, &size)
	}

	func transcriptData() -> Data {
		transcriptLock.lock()
		defer { transcriptLock.unlock() }
		return transcript
	}

	private func appendTranscript(_ data: Data) {
		transcriptLock.lock()
		transcript.append(data)
		if transcript.count > Self.transcriptCap {
			transcript.removeFirst(transcript.count - Self.transcriptCap)
		}
		transcriptLock.unlock()
	}

	deinit { stop() }
}
