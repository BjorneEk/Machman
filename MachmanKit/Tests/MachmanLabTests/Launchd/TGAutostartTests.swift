//
//  TGAutostartTests.swift
//  MachmanLabTests
//
//  launchd tier (T4: lab.sh --launchd only) — the autostart matrix. A VM's Start at login
//  writes its job plist into the scope's fake home and launches nothing; loaded by hand
//  (`launchctl bootstrap`, as at login) the job boots the VM with no agent, the agent adopts
//  it once, a guest power-off isn't respawned, a start before adoption probe-adopts, and
//  turning the switch off removes the plist (booting the job out only when nothing runs).
//  Every job a test loads is booted out on every path; the real log-out/log-in stays
//  Deferred: assisted.
//

import Foundation
import Testing
import MachmanAPI

@Suite("Autostart under launchd", .serialized, .enabled(if: Lab.runs(.launchd)))
struct TGAutostartTests {
	static let atLogin = StartPolicy(windowed: false, autostart: true)
	static let manual = StartPolicy(windowed: false)

	@Test("Autostart matrix: turning Start at login on writes the plist and launches nothing")
	func plistWrittenNothingLaunched() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("tg-am1", on: agent)
			let path = TGLaunchd.plistPath(agent.scope, vm.name)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let job = try TGLaunchd.readPlist(path)
			#expect(job.label == TGLaunchd.label(vm.name))
			#expect(job.runAtLoad == true)
			#expect(job.keepAlive == false)
			#expect(job.sessionType == "Aqua")
			let executable = try #require(job.arguments.first)
			#expect(executable.hasPrefix(Lab.productsDir + "/"))
			#expect(executable.hasSuffix("/MachmanVMHost"))
			#expect(Array(job.arguments.dropFirst()) == [
				"--data-dir", TG.vmsDir(agent.scope), "--vm", vm.name, "--socket", vm.socketPath,
				"--autostart",
			])
			let env = job.environment
			#expect(env["MACHMAN_SUITE_ID"] == Lab.suiteID)
			#expect(env["CFFIXED_USER_HOME"] == agent.scope.homeDir)
			#expect(env["HOME"] == agent.scope.homeDir)
			#expect(env["MACHMAN_DATA_DIR"] == agent.scope.dataDir)
			#expect(env["MACHMAN_LAB_ANSWERS"] == agent.scope.answersPath)
			#expect(env["MACHMAN_LAB"] == nil)
			#expect(env["PATH"] == nil)
			// Written, never loaded: nothing runs.
			try await Task.sleep(for: .seconds(3))
			#expect(try await TGLaunchd.state(job.label).loaded == false)
			#expect(await !TG.isSocketLive(vm.socketPath))
			#expect(try await TG.vmhostPids(socketPath: vm.socketPath).isEmpty)
		}
	}

	@Test("Autostart matrix: rename moves the plist and delete removes it")
	func renameMovesDeleteRemoves() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("tg-am5", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let old = TGLaunchd.plistPath(agent.scope, "tg-am5")
			#expect(FileManager.default.fileExists(atPath: old))
			try await agent.api.renameVM(named: "tg-am5", to: "tg-am5b")
			let new = TGLaunchd.plistPath(agent.scope, "tg-am5b")
			#expect(!FileManager.default.fileExists(atPath: old))
			let job = try TGLaunchd.readPlist(new)
			#expect(job.label == TGLaunchd.label("tg-am5b"))
			#expect(job.arguments.contains("tg-am5b"))
			#expect(!job.arguments.contains("tg-am5"))
			try await agent.api.deleteVM(named: "tg-am5b")
			#expect(!FileManager.default.fileExists(atPath: new))
		}
	}
}
