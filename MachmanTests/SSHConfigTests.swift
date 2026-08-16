//
//  SSHConfigTests.swift
//  MachmanTests
//
//  The persisted ssh sub-struct (1.0.6): present-key round-trip, absent-key default, the
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
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil, alias: nil)
			raw = try String(contentsOfFile: vm.configPath(), encoding: .utf8)
			#expect(raw.contains("\"ssh\""))
			let loaded = try VMConfig.load(name: "sshvm")
			#expect(loaded.ssh?.integrationEnabled == true)
			#expect(loaded.ssh?.reverseStateValue == SSHInfo.ReverseState.none)
		}
	}

	// The 1.0.6 additions survive a save/load cycle — the three-site lockstep guard.
	@Test @MainActor func newFieldsRoundTripThroughDisk() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshfields")
			let vm = try VMConfig(name: "sshfields", memorySize: 1 << 30, cpuCount: 2)
			var state = SSHConfig()
			state.alias = "dev"
			state.lastAddress = "192.168.64.7"
			state.guestOSVersion = "15.1"
			state.lastRunStatus = "partial"
			state.lastRunNote = "user mounts are off"
			state.lastTransport = "sshfs"
			state.scriptVersion = 2
			state.sshfsAvailable = true
			state.sshfsMountReady = false
			state.sshfsMountRoot = "/mnt/machman"
			vm.ssh = state
			try vm.saveVMConfig()
			#expect(try VMConfig.load(name: "sshfields").ssh == state)
		}
	}

	// The alias becomes an ssh_config Host pattern, so what it may contain is not a matter
	// of taste: a glob would capture unrelated hosts.
	@Test @MainActor func aliasIsValidatedAndResettable() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshalias")
			let vm = try VMConfig(name: "sshalias", memorySize: 1 << 30, cpuCount: 2)
			#expect(vm.effectiveSSHAlias == "sshalias.machman")

			try vm.setSSH(integrationEnabled: nil, reverseApproved: nil, alias: "  dev  ")
			#expect(vm.ssh?.alias == "dev")
			#expect(vm.effectiveSSHAlias == "dev")

			for bad in ["dev *", "dev?", "-dev", "de v", "a/b", "#dev", "dev\"",
				String(repeating: "a", count: 65)] {
				#expect(throws: MachmanError.self, "\(bad) should be refused") {
					try vm.setSSH(integrationEnabled: nil, reverseApproved: nil, alias: bad)
				}
			}
			#expect(vm.ssh?.alias == "dev")   // a refused alias changes nothing

			// Empty means "back to the default", not "an empty Host name".
			try vm.setSSH(integrationEnabled: nil, reverseApproved: nil, alias: "")
			#expect(vm.ssh?.alias == nil)
			#expect(vm.effectiveSSHAlias == "sshalias.machman")
		}
	}

	@Test @MainActor func reverseApprovalNeedsAReportedKey() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshrev")
			let vm = try VMConfig(name: "sshrev", memorySize: 1 << 30, cpuCount: 2)
			// Approving with no reported key is refused — nothing to install.
			#expect(throws: MachmanError.self) {
				try vm.setSSH(integrationEnabled: nil, reverseApproved: true, alias: nil)
			}
			var state = SSHConfig()
			state.reversePublicKey = "ssh-ed25519 AAAA guest"
			vm.ssh = state
			try vm.setSSH(integrationEnabled: nil, reverseApproved: true, alias: nil)
			#expect(vm.ssh?.reverseStateValue == .approved)
			// Saying no is an answer: the key stays on file as DENIED, not back in the
			// queue as pending — otherwise the UI would ask about it again forever.
			try vm.setSSH(integrationEnabled: nil, reverseApproved: false, alias: nil)
			#expect(vm.ssh?.reverseStateValue == .denied)
			// Re-reporting the SAME key does not re-open the question…
			#expect(!(try SSHReport.parse("REVERSE_PUBKEY=ssh-ed25519 AAAA guest")
				.apply(to: vm, stampedAt: Date())))
			#expect(vm.ssh?.reverseStateValue == .denied)
			// …but a DIFFERENT key is a new request.
			#expect(try SSHReport.parse("REVERSE_PUBKEY=ssh-ed25519 BBBB fresh")
				.apply(to: vm, stampedAt: Date()))
			#expect(vm.ssh?.reverseStateValue == .pending)
		}
	}

	@Test @MainActor func resetForgetsStateAndFiles() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshreset")
			let vm = try VMConfig(name: "sshreset", memorySize: 1 << 30, cpuCount: 2)
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil, alias: nil)
			let fm = FileManager.default
			let payloads = [SSHSetupInfo.directoryName, SSHSetupInfo.reportDirectoryName]
			var paths = [vm.configFilePath(file: "ssh")]
			for dir in payloads {
				paths.append(GuestInstallerWriter.payloadPath(named: dir, for: vm))
				// Pre-<vmdir>/share leftovers are cleaned up too.
				paths.append(vm.configFilePath(file: dir))
			}
			for path in paths {
				try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
			}
			try vm.resetSSH()
			#expect(vm.ssh == nil)
			for path in paths {
				#expect(!fm.fileExists(atPath: path))
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
