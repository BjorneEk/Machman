//
//  VMFolderPath.swift
//  MachmanCore
//
//  Where a VM's folder is now (E11): a descriptor held open on it follows a rename or a move,
//  so a vmhost can say which folder it serves even after Finder renamed it under the running
//  VM — the path it was launched with names nothing by then. nil once the folder is deleted,
//  or once let go of (a safe run saved as a new VM no longer serves the real VM's folder).
//

import Foundation

final class VMFolderPath: @unchecked Sendable {
	private let lock = NSLock()
	private var fd: Int32

	init(_ path: String) {
		fd = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
	}

	deinit {
		if fd >= 0 { close(fd) }
	}

	// Lets go of the folder: the process holds it open no longer (E70 reads what it holds).
	func release() {
		let held: Int32 = lock.withLock {
			defer { fd = -1 }
			return fd
		}
		if held >= 0 { close(held) }
	}

	var current: String? {
		let fd = lock.withLock { self.fd }
		guard fd >= 0 else { return nil }
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
		let path = String(cString: buffer)
		// A deleted folder still answers its last path, and its link count can lag: the path
		// counts only while it still names this folder.
		var held = stat()
		var named = stat()
		guard fstat(fd, &held) == 0, stat(path, &named) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return nil }
		return path
	}
}
