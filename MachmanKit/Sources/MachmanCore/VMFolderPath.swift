//
//  VMFolderPath.swift
//  MachmanCore
//
//  Where a VM's folder is now (E11): a descriptor held open on it follows a rename or a move,
//  so a vmhost can say which folder it serves even after Finder renamed it under the running
//  VM — the path it was launched with names nothing by then. nil once the folder is deleted.
//

import Foundation

final class VMFolderPath: @unchecked Sendable {
	private let fd: Int32

	init(_ path: String) {
		fd = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
	}

	deinit {
		if fd >= 0 { close(fd) }
	}

	var current: String? {
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
