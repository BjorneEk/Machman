//
//  SSHConfigTests.swift
//  MachmanTests
//
//  The persisted ssh sub-struct (1.0.5): present-key round-trip, absent-key default, the
//  conditional encode that keeps untouched configs byte-identical, and the reset wipe.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SSHConfigTests {

	@Test @MainActor func sshStateRoundTripsThroughDisk() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshvm")
			let vm = try VMConfig(name: "sshvm", memorySize: 1 << 30, cpuCount: 2)
			// A fresh config carries no ssh key at all (conditional encode).
			var raw = try String(contentsOfFile: vm.configPath(), encoding: .utf8)
			#expect(!raw.contains("\"ssh\""))
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil)
			raw = try String(contentsOfFile: vm.configPath(), encoding: .utf8)
			#expect(raw.contains("\"ssh\""))
			let loaded = try VMConfig.load(name: "sshvm")
			#expect(loaded.ssh?.integrationEnabled == true)
			#expect(loaded.ssh?.reverseStateValue == SSHInfo.ReverseState.none)
		}
	}

	@Test @MainActor func reverseApprovalNeedsAReportedKey() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshrev")
			let vm = try VMConfig(name: "sshrev", memorySize: 1 << 30, cpuCount: 2)
			// Approving with no reported key is refused — nothing to install.
			#expect(throws: MachmanError.self) {
				try vm.setSSH(integrationEnabled: nil, reverseApproved: true)
			}
			var state = SSHConfig()
			state.reversePublicKey = "ssh-ed25519 AAAA guest"
			vm.ssh = state
			try vm.setSSH(integrationEnabled: nil, reverseApproved: true)
			#expect(vm.ssh?.reverseStateValue == .approved)
			// Revoking with the key still on file goes back to pending, not none.
			try vm.setSSH(integrationEnabled: nil, reverseApproved: false)
			#expect(vm.ssh?.reverseStateValue == .pending)
		}
	}

	@Test @MainActor func resetForgetsStateAndFiles() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshreset")
			let vm = try VMConfig(name: "sshreset", memorySize: 1 << 30, cpuCount: 2)
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil)
			let fm = FileManager.default
			let dirs = ["ssh", SSHSetupInfo.directoryName, SSHSetupInfo.reportDirectoryName]
			for dir in dirs {
				try fm.createDirectory(
					atPath: vm.configFilePath(file: dir), withIntermediateDirectories: true)
			}
			try vm.resetSSH()
			#expect(vm.ssh == nil)
			for dir in dirs {
				#expect(!fm.fileExists(atPath: vm.configFilePath(file: dir)))
			}
			let raw = try String(contentsOfFile: vm.configPath(), encoding: .utf8)
			#expect(!raw.contains("\"ssh\""))
		}
	}

	// A future daemon's unknown reverseState string survives this daemon's load/save cycle.
	@Test func unknownReverseStateSurvives() throws {
		let json = Data(#"{"reverseState":"futureThing"}"#.utf8)
		let decoded = try JSONDecoder().decode(SSHConfig.self, from: json)
		#expect(decoded.reverseState == "futureThing")
		#expect(decoded.reverseStateValue == .unknown)
		let re = try JSONEncoder().encode(decoded)
		#expect(String(data: re, encoding: .utf8)!.contains("futureThing"))
	}
}
