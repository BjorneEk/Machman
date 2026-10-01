//
//  PTYChild.swift
//  MachmanUI
//
//  A process started on a fresh pty that is its CONTROLLING terminal: posix_spawn makes it a
//  session leader (POSIX_SPAWN_SETSID) and its first open of the pty's slave makes that its
//  controlling tty. Only then does a TIOCSWINSZ on the master signal SIGWINCH to it (ssh
//  forwards a resize on SIGWINCH alone), and only then can it open /dev/tty for a password
//  prompt (P20). posix_spawn rather than forkpty: no Swift code runs between fork and exec,
//  and POSIX_SPAWN_CLOEXEC_DEFAULT keeps every other descriptor of the app out of the child.
//
//  The child is reaped on its own serial queue the moment it exits, whether or not anyone
//  still listens, and signalled only on that queue before the reap — so it never lingers as a
//  zombie and a signal can never reach a recycled pid.
//

import Foundation

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
		defer { close(slave) }   // the child opens the slave itself, by name
		var name = [CChar](repeating: 0, count: 128)
		guard ptsname_r(master, &name, name.count) == 0 else {
			close(master)
			return nil
		}

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		// The new session leader's first tty open makes that tty its controlling terminal.
		posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
		posix_spawn_file_actions_adddup2(&actions, 0, 1)
		posix_spawn_file_actions_adddup2(&actions, 0, 2)
		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		var all = sigset_t()
		sigfillset(&all)
		var none = sigset_t()
		sigemptyset(&none)
		posix_spawnattr_setsigdefault(&attributes, &all)
		posix_spawnattr_setsigmask(&attributes, &none)
		posix_spawnattr_setflags(&attributes, Int16(
			POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
				| POSIX_SPAWN_SETSIGMASK))

		let argv = ([executablePath] + arguments).map { strdup($0) } + [nil]
		let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
		defer {
			argv.forEach { free($0) }
			envp.forEach { free($0) }
		}
		var pid: pid_t = 0
		guard posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp) == 0 else {
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
		// Strong on purpose: the child stays watched until it is reaped, even after the
		// stream that started it is gone. The reap cancels the source, which lets go of this.
		source.setEventHandler { [self] in reap() }
		self.source = source
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
