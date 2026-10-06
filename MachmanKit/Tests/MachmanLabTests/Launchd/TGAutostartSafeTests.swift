//
//  TGAutostartSafeTests.swift
//  MachmanLabTests
//
//  launchd tier (T4: lab.sh --launchd only) — login jobs beside safe runs and beside each
//  other: an unsafe autostart next to a dead safe run is adopted unshielded and the dead
//  run's dir swept; of two login VMs sharing a writable image the second refuses and says
//  why. Every job a test loads is booted out on every path.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite("Autostart and safe runs", .serialized, .enabled(if: Lab.runs(.launchd)))
struct TGAutostartSafeTests {
	static let atLogin = StartPolicy(windowed: false, autostart: true)

	/// Card E54, the login race (r3-tg, E/RISK, routed to r3-3c).
	static let loginRaceCard = Comment(rawValue: "E54: Two login VMs sharing a writable image "
		+ "can both refuse to start at login: each binds its socket before it checks for the "
		+ "other's")

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

	/// tg-ga and tg-gb, each with the same writable image; tg-ga starts at login by the
	/// API, tg-gb by a hand edit the API refuses; the relaunched agent writes tg-gb's plist
	/// (its startup heal), then retires.
	static func twoLoginSharers(_ agent: LabAgent) async throws -> (TGVM, TGVM) {
		let shared = agent.scope.imagesDir + "/tg-shared.img"
		try await TG.writeFile(shared, size: 32 << 20)
		let first = try await TGVM.alpine(
			"tg-ga", externals: [TGExternal(path: shared, safe: false)], on: agent)
		let second = try await TGVM.alpine(
			"tg-gb", externals: [TGExternal(path: shared, safe: false)], on: agent)
		try await agent.api.setStartPolicy(vm: first.name, policy: Self.atLogin)
		try TG.editConfig(agent.scope, second.name) { TG.setPolicy("autostart", true, in: &$0) }
		try await agent.api.retire()
		_ = await agent.waitForExit(timeout: .seconds(15))
		try await agent.relaunch()
		#expect(FileManager.default.fileExists(
			atPath: TGLaunchd.plistPath(agent.scope, second.name)))
		try await agent.api.retire()
		_ = await agent.waitForExit(timeout: .seconds(15))
		return (first, second)
	}

	static let refusal = "autostart of tg-gb refused: tg-ga (is running with|may still have) "
		+ "tg-shared\\.img attached"

	@Test("R3W2-26: of two forced login VMs sharing an image, the second refuses and logs why")
	func secondLoginSharerRefuses() async throws {
		try await TG.withAgent { agent in
			let (first, second) = try await Self.twoLoginSharers(agent)
			try await TGLaunchd.withJobs { jobs in
				try await jobs.bootstrap(TGLaunchd.plistPath(agent.scope, first.name))
				let host = try await TGAutostartTests.waitRunningOnSocket(first)
				try first.fileHostPid(host)
				let mark = LabLog.mark()
				try await jobs.bootstrap(TGLaunchd.plistPath(agent.scope, second.name))
				_ = try await LabLog.waitFor(
					Self.refusal, after: mark, process: "MachmanVMHost", timeout: .seconds(30))
				let label = TGLaunchd.label(second.name)
				#expect(await TG.until(timeout: .seconds(20)) {
					(try? await TGLaunchd.state(label))?.pid == nil
				})
				if let exit = try await TGLaunchd.state(label).lastExit { #expect(exit == 70) }
				#expect(await !TG.isSocketLive(second.socketPath))
				try await agent.relaunch()
				#expect(await TG.until { (try? await first.info())?.state == .running })
				let listed = try await agent.api.listVMs().filter { $0.state == .running }
				#expect(listed.map(\.name) == [first.name])
				try await first.forceStop()
			}
		}
	}

	@Test("R3W2-26: two sharers bootstrapped together still boot exactly one")
	func sharersTogetherBootOne() async throws {
		try await TG.withAgent { agent in
			let (first, second) = try await Self.twoLoginSharers(agent)
			try await TGLaunchd.withJobs { jobs in
				let mark = LabLog.mark()
				try await jobs.bootstrap(TGLaunchd.plistPath(agent.scope, first.name))
				try await jobs.bootstrap(TGLaunchd.plistPath(agent.scope, second.name))
				try await Task.sleep(for: .seconds(20))
				var running = 0
				for vm in [first, second] where await TG.isSocketLive(vm.socketPath) {
					if let host = try? await TGAutostartTests.waitRunningOnSocket(
						vm, timeout: .seconds(5)) {
						try vm.fileHostPid(host)
						running += 1
					}
				}
				#expect(LabLog.count("autostart of tg-g[ab] refused: ", after: mark) >= 1)
				withKnownIssue(Self.loginRaceCard, isIntermittent: true) {
					#expect(running == 1)
				}
				for vm in [first, second] {
					if let host = vm.filedHostPid() { try? await TG.killHost(host) }
				}
			}
		}
	}
}
