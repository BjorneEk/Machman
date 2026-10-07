//
//  VMHostProcess.swift
//  MachmanCore
//
//  This user's MachmanVMHost processes, seen from outside: by their executable, and by the
//  socket each was launched to serve (`--socket`, which the agent's spawn and an autostart job
//  both pass). The answer when a socket can't give one (E61): a vmhost that never accepts —
//  frozen, SIGSTOPped — keeps every probe's connection in its accept queue for good, and once
//  the queue is full a connect is refused as if nothing served the path.
//

import Foundation

enum VMHostProcess {
	// Whether `pid` runs the MachmanVMHost executable — still, not merely once: a pid kept
	// from a connect may belong to something else once the vmhost is gone.
	static func isVMHost(_ pid: pid_t) -> Bool {
		var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
		guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
		return String(cString: path)
			.hasSuffix("/" + VMHostLocator.bundleName + "/Contents/MacOS/MachmanVMHost")
	}

	// The live vmhost, other than this process, launched to serve the socket at `path`; nil
	// when there is none. A run saved as a new VM moved its socket away from its launch path,
	// so it is not found by the new one.
	static func serving(socketPath path: String) -> pid_t? {
		if let pid = TestHook.serving(path) { return pid }
		let me = getpid()
		let wanted = canonical(path)
		for pid in userPIDs() where pid != me && isVMHost(pid) {
			guard let argv = arguments(of: pid), let served = socketArgument(argv) else {
				continue
			}
			if served == path || canonical(served) == wanted { return pid }
		}
		return nil
	}

	// The path after a vmhost's `--socket`, nil without one.
	static func socketArgument(_ argv: [String]) -> String? {
		guard let flag = argv.firstIndex(of: "--socket"), flag + 1 < argv.count else {
			return nil
		}
		return argv[flag + 1]
	}

	// A process's argv as the kernel keeps it (KERN_PROCARGS2: argc, the executable path and
	// its padding, then the arguments); nil once it is gone or not this user's.
	static func arguments(of pid: pid_t) -> [String]? {
		var argmax: Int32 = 0
		var size = MemoryLayout<Int32>.size
		var argmaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
		guard sysctl(&argmaxName, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
		var buffer = [UInt8](repeating: 0, count: Int(argmax))
		size = buffer.count
		var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
		guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
		else { return nil }
		let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
		var index = MemoryLayout<Int32>.size
		while index < size, buffer[index] != 0 { index += 1 }   // the executable path
		while index < size, buffer[index] == 0 { index += 1 }   // its padding
		var argv: [String] = []
		while argv.count < argc, index < size {
			let start = index
			while index < size, buffer[index] != 0 { index += 1 }
			argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
			index += 1
		}
		return argv.count == argc ? argv : nil
	}

	private static func userPIDs() -> [pid_t] {
		let type = UInt32(PROC_UID_ONLY)
		let uid = UInt32(getuid())
		let bytes = proc_listpids(type, uid, nil, 0)
		guard bytes > 0 else { return [] }
		// Room for processes started between the two calls.
		var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
		let filled = proc_listpids(
			type, uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
		guard filled > 0 else { return [] }
		return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
	}

	private static func canonical(_ path: String) -> String {
		guard let resolved = realpath(path, nil) else { return path }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	// Tests only: the process that plays the vmhost serving a path (an in-process listener's
	// is the test itself, which is no vmhost), by path. Empty in production.
	enum TestHook {
		private static let lock = NSLock()
		nonisolated(unsafe) private static var servers: [String: pid_t] = [:]

		static func setServing(_ path: String, _ pid: pid_t?) {
			lock.withLock { servers[path] = pid }
		}

		static func serving(_ path: String) -> pid_t? {
			lock.withLock { servers[path] }
		}
	}
}
