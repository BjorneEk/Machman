//
//  main.swift
//  MachmanVMHost
//
//  Thin argv shell over VMHostBootstrap (MachmanCore). Launched by MachmanAgent as a standalone
//  app (and, with autostart, by launchd) — one process per running VM, its own TCC
//  responsible process:
//    MachmanVMHost --data-dir DIR --vm NAME --socket PATH
//

import Foundation
import MachmanCore

func usage() -> Never {
	FileHandle.standardError.write(Data(
		("usage: MachmanVMHost --data-dir DIR --vm NAME --socket PATH"
			+ " [--library DIR] [--autostart]\n").utf8))
	exit(64)
}

var dataDir: String?
var vmName: String?
var socketPath: String?
var library: String?
var autostart = false

var arguments = ArraySlice(CommandLine.arguments.dropFirst())
while let flag = arguments.popFirst() {
	if flag == "--autostart" {   // valueless: launchd-started hosts boot their own VM
		autostart = true
		continue
	}
	guard let value = arguments.popFirst() else { usage() }
	switch flag {
	case "--data-dir":
		dataDir = value
	case "--vm":
		vmName = value
	case "--socket":
		socketPath = value
	case "--library":   // safe runs only: the promotion destination for vm.safeSave
		library = value
	default:
		usage()
	}
}

guard let dataDir = dataDir, let vmName = vmName, let socketPath = socketPath else {
	usage()
}

// The vmhost's own bundle version, never the spawning daemon's (E22).
let version = VMHostVersion.current()
MainActor.assumeIsolated {
	VMHostBootstrap.run(
		dataDir: dataDir, vmName: vmName, socketPath: socketPath, daemonVersion: version,
		autostart: autostart, library: library)
}
