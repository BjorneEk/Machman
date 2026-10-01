//
//  PTYProcessStream.swift
//  MachmanUI
//
//  A TerminalByteStream backed by a local process on a PTY — the transport behind the
//  ephemeral SSH tabs. The descriptor side (reads, non-blocking sends, the transcript) is the
//  shared TerminalFDChannel; window sizes go to the pty via TIOCSWINSZ. Reports the session's
//  end as onClose exactly once, after the child's last output, whether the process quit or
//  the pty hung up first; an explicit stop() reports nothing.
//

import Foundation

public final class PTYProcessStream: TerminalByteStream {
	private let executablePath: String
	private let arguments: [String]
	private let environmentOverrides: [String: String]
	private var process: Process?
	private var channel: TerminalFDChannel?
	private var finished = false

	public var onData: ((Data) -> Void)?
	public var onClose: (() -> Void)?

	// environmentOverrides ride on top of the app's environment — a GUI app carries no
	// TERM, and without one ssh advertises TERM=dumb to the guest.
	public init(
		executablePath: String, arguments: [String],
		environmentOverrides: [String: String] = [:]
	) {
		self.executablePath = executablePath
		self.arguments = arguments
		self.environmentOverrides = environmentOverrides
	}

	// One process per stream: a second connect() is refused.
	public func connect() -> Bool {
		guard process == nil, !finished else { return false }
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
		let channel = TerminalFDChannel(fd: parent, label: "pty")
		// The child is gone: hand over what it printed last, then end.
		p.terminationHandler = { [weak channel] _ in
			DispatchQueue.main.async { channel?.drainAndEnd() }
		}
		do {
			try p.run()
		} catch {
			channel.close()   // owns the parent end now
			close(child)
			return false
		}
		close(child)   // the child's end lives inside the spawned process now
		process = p
		self.channel = channel
		channel.start(
			onData: { [weak self] data in
				guard let self, !self.finished else { return }
				self.onData?(data)
			},
			onEnd: { [weak self] in self?.finish() })
		return true
	}

	// The single end path (main queue): the pty hung up, or the child exited and its last
	// output was delivered.
	private func finish() {
		guard !finished else { return }
		finished = true
		if let p = process, p.isRunning { p.terminate() }
		onClose?()
	}

	public func send(_ data: Data) {
		channel?.send(data)
	}

	public func stop() {
		finished = true
		channel?.close()
		if let p = process {
			p.terminationHandler = nil   // no late callback after an explicit stop
			if p.isRunning { p.terminate() }
		}
	}

	public func setWindowSize(cols: Int, rows: Int) {
		guard cols > 0, rows > 0 else { return }
		let size = winsize(
			ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
			ws_xpixel: 0, ws_ypixel: 0)
		channel?.perform { fd in
			var value = size
			_ = ioctl(fd, TIOCSWINSZ, &value)
		}
	}

	public func transcriptData() -> Data {
		channel?.transcriptData() ?? Data()
	}

	deinit { stop() }
}
