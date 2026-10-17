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
		// A deleted folder still answers its last path; fstat says it is gone.
		var info = stat()
		guard fstat(fd, &info) == 0, info.st_nlink > 0 else { return nil }
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
		return String(cString: buffer)
	}
}
