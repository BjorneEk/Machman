//
//  TGSafeRecoveryTests.swift
//  MachmanLabTests
//
//  L2 — safe runs across an agent that goes away: a quit that leaves VMs running and a
//  relaunch re-attach the run (shield and history included), a killed vmhost ends its run
//  cleanly, a relaunch after both were killed sweeps the dead run's dir, and a saved run
//  answers on the saved VM's socket after a restart.
//

import Foundation
import Testing
import MachmanAPI
import MachmanUI

@Suite("Safe-run recovery", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGSafeRecoveryTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)

	static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

	@Test("9: an agent quit that leaves VMs running re-adopts the safe run with its shield")
	func quitAndRelaunchReattaches() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine(
				"tg-r9", disks: [TGDisk(name: "data", mib: 64)], policy: Self.safeHeadless,
				on: agent)
			let before = try await vm.info()
			try await vm.start(before.startOptions(.plain))
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let root = roots[0]
			let host = try await vm.hostPID()
			try await Task.sleep(for: .seconds(2))
			try await TG.quitLeavingVMsRunning(agent)
			#expect(LabProcesses.isAlive(host))
			#expect(FileManager.default.fileExists(atPath: root))
			let mark = LabLog.mark()
			try await agent.relaunch()
			let name = (root as NSString).lastPathComponent
			_ = try await LabLog.waitFor(
				"re-attached safe run " + Self.escaped(name) + " to tg-r9", after: mark,
				process: "MachmanAgent")
			#expect(await TG.until { (try? await vm.info())?.safeRun == true })
			#expect(try await vm.info().state == .running)
			#expect(try await vm.hostPID() == host)
			try await vm.forceStop()
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			// The session's history still reached the real VM.
			let after = try await vm.info()
			#expect((after.lastRan ?? .distantPast) > (before.lastRan ?? .distantPast))
			#expect((after.totalRuntimeSeconds ?? 0) >= (before.totalRuntimeSeconds ?? 0) + 2)
		}
	}

	@Test("10: a killed vmhost ends its safe run and leaves the real VM untouched")
	func killedHostEndsRun() async throws {
		try await TG.withAgent { agent in
			let data = TGDisk(name: "data", mib: 64)
			let vm = try await TGVM.alpine(
				"tg-r10", disks: [data], policy: Self.safeHeadless, on: agent)
			let real = vm.dir + "/data.raw"
			let before = try await TG.sha256(real)
			try await vm.start(try await vm.info().startOptions(.plain))
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.loadBlockDriver(count: 1)
				let device = try await guest.device(sectors: data.sectors)
				try await guest.writeMarker("TG10-" + TG.nonce(), device: device, sector: 8)
			}
			let host = try await vm.hostPID()
			try await TG.killHost(host)
			try await vm.stopped(host: host, timeout: .seconds(20))
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			#expect(try await TG.sha256(real) == before)
			#expect(try await vm.info().safeRun != true)
		}
	}

	@Test("11: a relaunched agent sweeps the run dir of a killed agent and vmhost")
	func relaunchSweepsDeadRun() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine(
				"tg-r11", disks: [TGDisk(name: "data", mib: 64)], policy: Self.safeHeadless,
				on: agent)
			try await vm.start(try await vm.info().startOptions(.plain))
			let roots = TG.runRoots(agent.scope)
			try #require(roots.count == 1)
			let host = try await vm.hostPID()
			// The agent first: a live agent would see its vmhost go and clean up itself.
			try await TG.killAgent(agent)
			try await TG.killHost(host)
			LabProcesses.removePid(kind: "vmhost", name: vm.pidName)
			#expect(FileManager.default.fileExists(atPath: roots[0]))
			let mark = LabLog.mark()
			try await agent.relaunch()
			let name = (roots[0] as NSString).lastPathComponent
			_ = try await LabLog.waitFor(
				"swept dead safe run " + Self.escaped(name), after: mark, process: "MachmanAgent")
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			let listed = try await agent.api.listVMs()
			#expect(listed.first { $0.name == "tg-r11" }?.state == .stopped)
			#expect(listed.allSatisfy { $0.safeRun != true })
		}
	}

	@Test("W2-38: after an agent restart the saved run answers on the saved VM's socket")
	func savedRunSocketSurvivesRestart() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("tg-o38", policy: Self.safeHeadless, on: agent)
			let kept = TGVM("tg-o38-kept", on: agent)
			try await vm.start(try await vm.info().startOptions(.plain))
			let host = try await vm.hostPID()
			let run = "run-" + TG.nonce()
			do {
				let guest = try await vm.guest()
				defer { guest.console.close() }
				try await guest.set("TGWHO", run)
			}
			_ = try await agent.api.safeSave(vm: "tg-o38", to: "tg-o38-kept")
			try vm.handOverPid(to: kept)
			try await TG.quitLeavingVMsRunning(agent)
			#expect(LabProcesses.isAlive(host))
			try await agent.relaunch()
			#expect(await TG.until { (try? await kept.info())?.state == .running })
			#expect(try await kept.info().safeRun != true)
			#expect(try await vm.info().state == .stopped)
			// The vmhost serves the saved VM's socket; the original's path is free.
			#expect(await TG.socketPeer(kept.socketPath) == host)
			#expect(!FileManager.default.fileExists(atPath: vm.socketPath))
			// A new console on the saved VM reaches the same shell.
			do {
				let guest = try await TGGuest.attach(try await kept.console(0))
				defer { guest.console.close() }
				#expect(try await guest.value(of: "TGWHO") == run)
			}
			try await kept.forceStop()
		}
	}
}
