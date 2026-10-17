//
//  VMHostProcess.swift
//  MachmanCore
//
//  This user's MachmanVMHost processes, seen from outside: by their executable, and by the
//  listening sockets they hold. The answer when a socket can't give one (E61): a vmhost that
//  never accepts — frozen, SIGSTOPped — keeps every probe's connection in its accept queue for
//  good, and once the queue is full a connect is refused as if nothing served the path. And
//  the VM folders a vmhost holds open (E70): what a silent one serves, read without asking it.
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

	// The live vmhost, other than this process, whose listener for the socket at `path` refuses
	// because its accept queue is full; nil when there is none. The listener is told by its
	// bind-time address, which the kernel keeps for life: the path itself, or the staging name
	// it was published from (BoundSocket.listen). Never by the vmhost's --socket argument: a run
	// saved as a new VM serves another path from then on, and a leftover file at the path it was
	// launched on read live while it ran — End Process there ended it (review F17).
	static func serving(socketPath path: String) -> pid_t? {
		listener(at: path, full: true)
	}

	// The live vmhost, other than this process, holding the listener for the socket at `path`
	// (told as `serving` tells it), whatever its queue holds — found without connecting, so a
	// vmhost that never accepts gains no connection from the look (E70).
	static func listener(at path: String) -> pid_t? {
		listener(at: path, full: false)
	}

	private static func listener(at path: String, full: Bool) -> pid_t? {
		let names = Set([path, BoundSocket.stagingPath(for: path)].map(canonical))
		let candidates = TestHook.serving(path).map { [$0] }
			?? userPIDs().filter { $0 != getpid() && isVMHost($0) }
		return candidates.first { holdsListener($0, boundAt: names, full: full) }
	}

	// Whether `pid` holds a listening unix socket bound at one of `names` whose accept queue is
	// full: what refuses a connect while it never accepts.
	static func holdsFullListener(_ pid: pid_t, boundAt names: Set<String>) -> Bool {
		holdsListener(pid, boundAt: names, full: true)
	}

	// A directory a process holds open: the path it names now (a descriptor follows a rename
	// or a move) and what it is. A deleted folder still reports its last path, where a new
	// folder may stand since — so a held folder is told by its identity, never its path (E70).
	struct HeldFolder: Equatable, Sendable {
		let path: String
		let device: UInt32
		let inode: UInt64

		init(path: String, device: UInt32, inode: UInt64) {
			self.path = path
			self.device = device
			self.inode = inode
		}

		// The folder at `path` now; nil when there is none.
		init?(at path: String) {
			var info = stat()
			guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
			self.init(path: path, device: UInt32(bitPattern: info.st_dev), inode: info.st_ino)
		}

		// Whether this is the folder at `other` now, by identity alone.
		func isFolder(at other: String) -> Bool {
			HeldFolder(at: other).map { $0.device == device && $0.inode == inode } ?? false
		}
	}

	// The directories `pid` holds open. A vmhost holds its VM's folder open for its whole run —
	// the folder its hello says it serves (VMFolderPath) — and a safe run's, the real VM's
	// folder too (E70).
	static func folders(of pid: pid_t) -> [HeldFolder] {
		descriptors(of: pid).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) }
			.compactMap { fd -> HeldFolder? in
				var info = vnode_fdinfowithpath()
				let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
				guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size
				else { return nil }
				let held = info.pvip.vip_vi.vi_stat
				guard held.vst_mode & S_IFMT == S_IFDIR else { return nil }
				let path = withUnsafeBytes(of: info.pvip.vip_path) {
					String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
				}
				return HeldFolder(path: path, device: held.vst_dev, inode: held.vst_ino)
			}
	}

	// Every descriptor `pid` holds.
	private static func descriptors(of pid: pid_t) -> [proc_fdinfo] {
		let entry = MemoryLayout<proc_fdinfo>.stride
		let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
		guard bytes > 0 else { return [] }
		// Room for descriptors opened between the two calls.
		var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / entry + 16)
		let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * entry))
		guard filled > 0 else { return [] }
		return Array(fds.prefix(Int(filled) / entry))
	}

	// Whether `pid` holds a listening unix socket bound at one of `names` — with `full`, one
	// whose accept queue is full.
	private static func holdsListener(_ pid: pid_t, boundAt names: Set<String>, full: Bool)
		-> Bool {
		for fd in descriptors(of: pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
			var info = socket_fdinfo()
			let size = Int32(MemoryLayout<socket_fdinfo>.size)
			guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size
			else { continue }
			let socket = info.psi
			guard socket.soi_family == AF_UNIX, Int32(socket.soi_options) & SO_ACCEPTCONN != 0,
				!full || (socket.soi_qlimit > 0 && socket.soi_qlen >= socket.soi_qlimit)
			else { continue }
			let bound = withUnsafeBytes(of: socket.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) {
				String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
			}
			if names.contains(canonical(bound)) { return true }
		}
		return false
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

	// A socket path with its directory resolved: a staging name no longer exists once it was
	// published, so only the directory can be.
	private static func canonical(_ path: String) -> String {
		let directory = (path as NSString).deletingLastPathComponent
		guard let resolved = realpath(directory, nil) else { return path }
		defer { free(resolved) }
		return String(cString: resolved) + "/" + (path as NSString).lastPathComponent
	}

	// Tests only: the process that plays the vmhost of a path — an in-process listener's is the
	// test itself, which is no vmhost — by path; its listeners are looked at as a vmhost's are.
	// Empty in production.
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
