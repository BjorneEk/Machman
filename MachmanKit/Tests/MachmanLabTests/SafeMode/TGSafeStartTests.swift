//
//  TGSafeStartTests.swift
//  MachmanLabTests
//
//  L2 — how a safe policy's VM starts: every plain Start (agent menu, desktop, the wire with
//  the policy's options) gives a safe headless run, and a login vmhost never autostarts a
//  VM whose hand-edited config asks for a safe run.
//

import Foundation
import Testing
import MachmanAPI
import MachmanDesktopCore
import MachmanUI

@Suite("Safe starts", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGSafeStartTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)

	enum Path: String, CaseIterable, Sendable {
		case agentStart = "the agent menu's Start"
		case agentStartHeadless = "the agent menu's Start Headless"
		case desktopStart = "the desktop's Start"
		case desktopStartHeadless = "the desktop's Start Headless"
		case wire = "vm.start with the policy's options"
	}

	// The vmhost's line for a windowed start under the test suite (it opens nothing).
	static func noWindowLine(_ vm: String) -> String {
		"test mode: no window for " + NSRegularExpression.escapedPattern(for: vm)
			+ " under the test suite"
	}

	@Test("W2-12a: every start path of a safe headless policy starts a safe headless run")
	func everyStartPathIsSafeAndHeadless() async throws {
		try await TG.withAgent { agent in
			// A display, so a windowed start has something to (not) open and says so.
			_ = try await LabVM.create(
				LabVMSpec(name: "safe-headless", boot: .alpine(), devices: [.graphics]),
				on: agent)
			let vm = TGVM("safe-headless", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.safeHeadless)
			// The instrument: a windowed start logs the vmhost's no-window line.
			var mark = LabLog.mark()
			try await vm.start(StartOptions(openWindow: true, safe: true))
			_ = try await LabLog.waitFor(
				Self.noWindowLine(vm.name), after: mark, process: "MachmanVMHost")
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			let desktop = try await TGDesktop.make(
				api: agent.api, scope: agent.scope, showing: vm.name)
			for path in Path.allCases {
				mark = LabLog.mark()
				try await Self.start(vm, by: path, agent: agent, desktop: desktop)
				try await vm.waitForState(.running, timeout: .seconds(90))
				try vm.fileHostPid(try await vm.hostPID())
				#expect(try await vm.info().safeRun == true, "\(path.rawValue)")
				#expect(TG.runRoots(agent.scope).count == 1, "\(path.rawValue)")
				// The windowed start's line came within a second of its run; none here.
				try await Task.sleep(for: .seconds(2))
				#expect(
					LabLog.count(Self.noWindowLine(vm.name), after: mark) == 0, "\(path.rawValue)")
				try await vm.forceStop()
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty, "\(path.rawValue)")
				#expect(await desktop.waitFor(vm.name, .stopped), "\(path.rawValue)")
			}
		}
	}

	static func start(_ vm: TGVM, by path: Path, agent: LabAgent, desktop: TGDesktop)
		async throws {
		switch path {
		case .agentStart:
			#expect(try await SeamProbe.control(agent, "menu start \(vm.name)") == "ok")
		case .agentStartHeadless:
			#expect(try await SeamProbe.control(agent, "menu startHeadless \(vm.name)") == "ok")
		case .desktopStart, .desktopStartHeadless:
			try await desktopStart(vm, headless: path == .desktopStartHeadless, desktop: desktop)
		case .wire:
			try await agent.api.start(vm: vm.name, options: try await vm.info().startOptions())
		}
	}

	@MainActor
	static func desktopStart(_ vm: TGVM, headless: Bool, desktop: TGDesktop) async throws {
		let info = try #require(desktop.vm(vm.name))
		#expect(info.state == .stopped)
		desktop.viewModel.startPolicyDriven(info, headless ? .headless : .plain)
	}

	@Test("14b: a login vmhost for a hand-edited autostart and safe VM exits 70 without booting")
	func loginHostRefusesSafeAutostart() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-edited", on: agent)
			let plist = TGLaunchd.plistPath(agent.scope, vm.name)
			defer { try? FileManager.default.removeItem(atPath: plist) }
			// The wire refuses the pair.
			let both = await #expect(throws: MachmanError.self) {
				try await agent.api.setStartPolicy(
					vm: vm.name, policy: StartPolicy(windowed: false, safe: true, autostart: true))
			}
			#expect(both?.code == .invalidArgument)
			#expect(both?.message == "A safe run can\u{2019}t start automatically")
			#expect(!FileManager.default.fileExists(atPath: plist))
			try await agent.api.setStartPolicy(
				vm: vm.name, policy: StartPolicy(windowed: false, autostart: true))
			let job = try TGLaunchd.readPlist(plist)
			#expect(job.label == TGLaunchd.label(vm.name))
			#expect(job.arguments.suffix(7) == [
				"--data-dir", TG.vmsDir(agent.scope), "--vm", vm.name, "--socket", vm.socketPath,
				"--autostart",
			])
			#expect(job.environment["MACHMAN_SUITE_ID"] == Lab.suiteID)
			// A hand edit puts both on; the login vmhost refuses before it boots anything.
			try TG.editConfig(agent.scope, vm.name) { TG.setPolicy("safe", true, in: &$0) }
			let mark = LabLog.mark()
			let result = try await TGLaunchd.spawnLikeLaunchd(job)
			#expect(result.status == 70)
			_ = try await LabLog.waitFor(
				"autostart of login-edited refused: safe runs cannot autostart", after: mark,
				process: "MachmanVMHost")
			#expect(await !TG.isSocketLive(vm.socketPath))
			#expect(TG.runRoots(agent.scope).isEmpty)
			#expect(try await vm.info().state == .stopped)
			// Undone by hand, the plist first: the agent never boots a job out in L2.
			try FileManager.default.removeItem(atPath: plist)
			try TG.editConfig(agent.scope, vm.name) { TG.setPolicy("safe", false, in: &$0) }
		}
	}
}
