//
//  main.swift
//  MachmanVMHost
//
//  Thin argv shell over VMHostBootstrap (MachmanCore). Spawned by Machmand, one per running VM:
//    MachmanVMHost --data-dir DIR --vm NAME --socket PATH
//

import Foundation
import MachmanCore

func usage() -> Never {
	FileHandle.standardError.write(Data(
		"usage: MachmanVMHost --data-dir DIR --vm NAME --socket PATH\n".utf8))
	exit(64)
}

var dataDir: String?
var vmName: String?
var socketPath: String?

var arguments = ArraySlice(CommandLine.arguments.dropFirst())
while let flag = arguments.popFirst() {
	guard let value = arguments.popFirst() else { usage() }
	switch flag {
	case "--data-dir":
		dataDir = value
	case "--vm":
		vmName = value
	case "--socket":
		socketPath = value
	default:
		usage()
	}
}

guard let dataDir = dataDir, let vmName = vmName, let socketPath = socketPath else {
	usage()
}

let version = ProcessInfo.processInfo.environment["MACHMAN_VERSION"] ?? "dev"
MainActor.assumeIsolated {
	VMHostBootstrap.run(
		dataDir: dataDir, vmName: vmName, socketPath: socketPath, daemonVersion: version)
}
