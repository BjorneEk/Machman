//
//  RunSocketPathTests.swift
//  MachmanTests
//
//  E27: a serial port's data-plane socket belongs to one run, not to the VM's name — a run
//  saved as a new VM keeps its ports, and no later run of either VM lands on its path.
//

import Testing
import Foundation
import MachmanAPI

struct RunSocketPathTests {
	@Test func eachRunGetsItsOwnPathAndKeepsIt() {
		let one = UUID().uuidString
		let other = UUID().uuidString
		let path = MachmanPaths.serialSocketPath(
			run: one, kind: "console", index: 0, runtimeDir: "/tmp/r")
		#expect(path == MachmanPaths.serialSocketPath(
			run: one, kind: "console", index: 0, runtimeDir: "/tmp/r"))
		#expect(path != MachmanPaths.serialSocketPath(
			run: other, kind: "console", index: 0, runtimeDir: "/tmp/r"))
		#expect(path != MachmanPaths.serialSocketPath(
			run: one, kind: "uart", index: 0, runtimeDir: "/tmp/r"))
		#expect(path != MachmanPaths.serialSocketPath(
			run: one, kind: "console", index: 1, runtimeDir: "/tmp/r"))
		#expect((path as NSString).lastPathComponent.hasPrefix("tty-"))   // the prune's match
	}

	@Test func runPathsStayWithinSunPath() {
		let runtime = MachmanPaths.runtimeDir(
			env: ["MACHMAN_SUITE_ID": "com.gustaffranzen.Machman.dev"])
		let path = MachmanPaths.serialSocketPath(
			run: UUID().uuidString, kind: "console", index: 9, runtimeDir: runtime)
		#expect(path.utf8.count < 104, "socket path too long for sun_path: \(path)")
	}
}
