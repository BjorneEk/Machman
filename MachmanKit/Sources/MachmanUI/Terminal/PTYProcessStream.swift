//
//  PTYProcessStream.swift
//  MachmanUI
//
//  A TerminalByteStream backed by a local process on a PTY — the transport behind the
//  ephemeral SSH tabs. The pty is the child's controlling terminal (PTYChild), so a window
//  size reaches it as SIGWINCH and it can prompt on /dev/tty; the descriptor side (reads,
//  non-blocking sends, the transcript) is the shared TerminalFDChannel. Reports the session's
//  end as onClose exactly once, after the child's last output, whether the process quit or
//  the pty hung up first; an explicit stop() reports nothing.
//

import Foundation

public final class PTYProcessStream: TerminalByteStream {
	private let executablePath: String
	private let arguments: [String]
	private let environmentOverrides: [String: String]
	private var child: PTYChild?
	private var channel: TerminalFDChannel?
	private var size: winsize?
	private var finished = false
	// A size change reaches the child once it has settled this long: each TIOCSWINSZ is a
	// SIGWINCH, and a full-screen guest app (vim, tmux, htop) repaints for every one (P34).
	// Longer than the terminal container's 100 ms resize cadence, so a drag in progress sends
	// nothing until it stops.
	static let resizeSettle: TimeInterval = 0.15
	private let schedule: (TimeInterval, @escaping () -> Void) -> Void
	private var resizeGeneration = 0
	// Test seam: the window sizes actually handed to the pty after connect().
	private(set) var windowSizeWrites = 0

	public var onData: ((Data) -> Void)?
	public var onClose: (() -> Void)?

	// environmentOverrides ride on top of the app's environment — a GUI app carries no
	// TERM, and without one ssh advertises TERM=dumb to the guest.
	public convenience init(
		executablePath: String, arguments: [String],
		environmentOverrides: [String: String] = [:]
	) {
		self.init(
			executablePath: executablePath, arguments: arguments,
			environmentOverrides: environmentOverrides,
			schedule: { delay, body in
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { body() }
			})
	}

	// `schedule` runs a body on the main thread after a delay (tests run it by hand).
	init(
		executablePath: String, arguments: [String], environmentOverrides: [String: String],
		schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
	) {
		self.executablePath = executablePath
		self.arguments = arguments
		self.environmentOverrides = environmentOverrides
		self.schedule = schedule
	}

	// One process per stream: a second connect() is refused.
	public func connect() -> Bool {
		guard child == nil, !finished else { return false }
		let environment = ProcessInfo.processInfo.environment
			.merging(environmentOverrides) { _, override in override }
		// The child is gone: hand over what it printed last, then end.
		guard let (child, master) = PTYChild.spawn(
			executablePath: executablePath, arguments: arguments, environment: environment,
			size: size, onExit: { [weak self] in self?.channel?.drainAndEnd() })
		else { return false }
		self.child = child
		let channel = TerminalFDChannel(fd: master, label: "pty")
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
		child?.terminate()
		onClose?()
	}

	public func send(_ data: Data) {
		channel?.send(data)
	}

	// Closing the pty hangs the session up (SIGHUP); the SIGTERM is for a child that
	// ignores that. Either way the child is reaped when it goes.
	public func stop() {
		finished = true
		channel?.close()
		child?.terminate()
	}

	// Before connect() the size is kept as the pty's first size. After it, only the last of
	// a run of changes reaches the pty, resizeSettle after the run ends. Main thread.
	public func setWindowSize(cols: Int, rows: Int) {
		guard cols > 0, rows > 0 else { return }
		size = winsize(
			ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
			ws_xpixel: 0, ws_ypixel: 0)
		guard channel != nil else { return }
		resizeGeneration += 1
		let generation = resizeGeneration
		schedule(Self.resizeSettle) { [weak self] in
			guard let self, generation == self.resizeGeneration, !self.finished,
				let channel = self.channel, let next = self.size else { return }
			self.windowSizeWrites += 1
			channel.perform { fd in
				var value = next
				_ = ioctl(fd, TIOCSWINSZ, &value)
			}
		}
	}

	public func transcriptData() -> Data {
		channel?.transcriptData() ?? Data()
	}

	// Test seam: the child's pid once spawned.
	var childPID: pid_t? { child?.pid }

	deinit { stop() }
}
