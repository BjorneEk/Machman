//
//  PTYChild.swift
//  MachmanUI
//
//  A process started on a fresh pty that is its CONTROLLING terminal: it leads a session of
//  its own and took the pty's slave with TIOCSCTTY (machman_pty_spawn, C). Only then does a
//  TIOCSWINSZ on the master signal SIGWINCH to it (ssh forwards a resize on SIGWINCH alone),
//  can it open /dev/tty for a password prompt (P20), and does closing the master — the app
//  quitting or crashing — hang it up with SIGHUP (P42). A plain posix_spawn gave none of
//  that: it runs its file actions before it makes the session. Not forkpty either: no Swift
//  runs between fork and exec, and every other descriptor of the app stays out of the child.
//
//  The child is reaped on its own serial queue the moment it exits, whether or not anyone
//  still listens, and signalled only on that queue before the reap — so it never lingers as a
//  zombie and a signal can never reach a recycled pid.
//

import Foundation
import MachmanAPI
import MachmanPTYSpawn

final class PTYChild: @unchecked Sendable {
	let pid: pid_t
	private let onExit: () -> Void
	private let queue: DispatchQueue
	private var source: DispatchSourceProcess?
	private var reaped = false

	// The child and the pty's master end, or nil when the pty or the spawn failed. size, when
	// given, is the pty's first window size — the child reads it before any resize can arrive.
	// onExit runs on the main queue, once, after the child was reaped.
	static func spawn(
		executablePath: String, arguments: [String], environment: [String: String],
		size: winsize?, onExit: @escaping () -> Void
	) -> (child: PTYChild, master: Int32)? {
		var master: Int32 = -1
		var slave: Int32 = -1
		var firstSize = size ?? winsize()
		let opened = size == nil
			? openpty(&master, &slave, nil, nil, nil)
			: openpty(&master, &slave, nil, nil, &firstSize)
		guard opened == 0 else { return nil }
		_ = fcntl(master, F_SETFD, FD_CLOEXEC)
		_ = fcntl(slave, F_SETFD, FD_CLOEXEC)
		defer { close(slave) }   // the child has its own copies, on 0, 1 and 2

		let argv = ([executablePath] + arguments).map { strdup($0) } + [nil]
		let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
		defer {
			argv.forEach { free($0) }
			envp.forEach { free($0) }
		}
		let pid = machman_pty_spawn(executablePath, argv, envp, slave)
		guard pid > 0 else {
			let reason = String(cString: strerror(errno))
			MachmanLogger.log(
				.interactionWarning, "\(executablePath) didn't start on a pty: \(reason)")
			close(master)
			return nil
		}
		return (PTYChild(pid: pid, onExit: onExit), master)
	}

	private init(pid: pid_t, onExit: @escaping () -> Void) {
		self.pid = pid
		self.onExit = onExit
		queue = DispatchQueue(label: "machman.pty.child")
		let source = DispatchSource.makeProcessSource(
			identifier: pid, eventMask: .exit, queue: queue)
		// Stored before the handler is set: reap() reads it on the queue, and setting the
		// handler is the hand-off ThreadSanitizer sees (it does not see resume() as one).
		self.source = source
		// Strong on purpose: the child stays watched until it is reaped, even after the
		// stream that started it is gone. The reap cancels the source, which lets go of this.
		source.setEventHandler { [self] in reap() }
		source.resume()
	}

	// SIGTERM, only while the pid is still ours.
	func terminate() {
		queue.async { [self] in
			if !reaped { kill(pid, SIGTERM) }
		}
	}

	// The exit event can come a moment before the child is waitable, so this waits (briefly)
	// instead of polling once and losing the only event it gets.
	private func reap() {
		guard !reaped else { return }
		var status: Int32 = 0
		while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
		reaped = true
		source?.cancel()
		source = nil
		DispatchQueue.main.async(execute: onExit)
	}
}
