//
//  TGAutostartSafeTests.swift
//  MachmanLabTests
//
//  launchd tier (T4: lab.sh --launchd only) — a login job beside a safe run: an unsafe
//  autostart next to a dead safe run is adopted unshielded and the dead run's dir swept.
//  Every job a test loads is booted out on every path.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite("Autostart and safe runs", .serialized, .enabled(if: Lab.runs(.launchd)))
struct TGAutostartSafeTests {
	static let atLogin = StartPolicy(windowed: false, autostart: true)

	static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

	@Test("12: an unsafe autostart beside a dead safe run is adopted unshielded and the dir swept")
	func unsafeAutostartBesideDeadSafeRun() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine(
				"tg-r12", disks: [TGDisk(name: "data", mib: 64)], on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			try await vm.start(StartOptions(openWindow: false, safe: true))
			#expect(try await vm.info().safeRun == true)
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let dead = try await vm.hostPID()
			// A stale shadow: the agent, then its vmhost, killed.
			try await TG.killAgent(agent)
			try await TG.killHost(dead)
			LabProcesses.removePid(kind: "vmhost", name: vm.pidName)
			#expect(TG.marker(roots[0])?.pid == dead)
			try await TGLaunchd.withJobs { jobs in
				try await jobs.bootstrap(TGLaunchd.plistPath(agent.scope, vm.name))
				let host = try await TGAutostartTests.waitRunningOnSocket(vm)
				try vm.fileHostPid(host)
				#expect(host != dead)
				let mark = LabLog.mark()
				try await agent.relaunch()
				let name = (roots[0] as NSString).lastPathComponent
				_ = try await LabLog.waitFor(
					"swept dead safe run " + Self.escaped(name), after: mark,
					process: "MachmanAgent")
				#expect(await TG.until { (try? await vm.info())?.state == .running })
				#expect(try await vm.info().safeRun != true)
				#expect(try await vm.hostPID() == host)
				#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
				// An unsafe run: its run defaults stay editable.
				try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
				try await vm.forceStop()
			}
		}
	}
}
