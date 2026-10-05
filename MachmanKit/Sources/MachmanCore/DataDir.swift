//
//  DataDir.swift
//  MachmanCore
//
//  The engine's view of where things live. Resolution itself lives in MachmanAPI (MachmanPaths)
//  so clients can find the daemon's socket without linking the engine; this file pins the
//  resolved values into the mutable globals the engine uses (tests swap them via VMTestSupport).
//
//  These initializers are deliberately side-effect free. A vmhost overwrites machmanVMDir from
//  its --data-dir argument, and touching a global runs its initializer first — so creating
//  directories here would have every dev vmhost mkdir the PRODUCTION path on the way past.
//  Directories are created at the point of use instead.
//
//  There is no development-vs-production guard any more. The suite identifier differs between
//  Debug and Release builds, so the two resolve to different libraries by construction.
//

import Foundation
import MachmanAPI

// The VM library: <dataDir>/VMs. Every VM is a directory directly inside it.
var machmanVMDir: String = MachmanPaths.vmsDir()

// Sockets and other per-boot state, deliberately outside the VM library — see MachmanPaths for
// why (sun_path is 104 bytes, and the library may sit on a volume that cannot host a socket).
var machmanRuntimeDir: String = MachmanPaths.runtimeDir()

// Safe-run shadows: <dataDir>/safe, a sibling of the VMs dir (same volume by construction,
// outside the registry scan). Only the daemon reads this; a vmhost is handed its run root.
var machmanSafeDir: String = MachmanPaths.safeRunsDir(dataDir: MachmanPaths.dataDir())

func machmanSocketPath() -> String {
	machmanRuntimeDir + "/machman.sock"
}

func machmanVMSocketPath(vm name: String) -> String {
	MachmanPaths.vmSocketPath(vm: name, runtimeDir: machmanRuntimeDir)
}

@discardableResult
func ensureDirectory(_ path: String) -> Bool {
	do {
		try FileManager.default.createDirectory(
			atPath: path, withIntermediateDirectories: true, attributes: nil)
		return true
	} catch {
		return false
	}
}

// ensureDirectory's counterpart for container dirs (share/, kernels/, ~/.ssh/machman/):
// they have no reason to outlive their contents, but a dir holding ANYTHING unexpected is
// left alone. Reports whether the directory is gone (a missing one already is).
@discardableResult
func removeEmptyDirectory(_ path: String) -> Bool {
	let fm = FileManager.default
	guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
		return !fm.fileExists(atPath: path)
	}
	guard contents.isEmpty else { return false }
	try? fm.removeItem(atPath: path)
	return !fm.fileExists(atPath: path)
}

// Time Machine must not copy VM disks: they are large, rewritten constantly, and worthless in a
// half-captured state. Applied when a disk is created AND on every registry scan, because every
// image that exists today predates this call and would otherwise never be marked.
func excludeFromBackup(path: String) {
	guard FileManager.default.fileExists(atPath: path) else { return }
	var url = URL(fileURLWithPath: path)
	var values = URLResourceValues()
	values.isExcludedFromBackup = true
	try? url.setResourceValues(values)
}

// A file's size with symlinks followed: a disk image reached through a link measures as the
// image, never as the link (FileManager.attributesOfItem is lstat — D23). nil when nothing is
// there.
func fileSize(atPath path: String) -> UInt64? {
	var info = stat()
	guard stat(path, &info) == 0 else { return nil }
	return UInt64(max(info.st_size, 0))
}
