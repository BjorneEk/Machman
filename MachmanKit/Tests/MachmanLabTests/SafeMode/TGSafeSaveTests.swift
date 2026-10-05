//
//  TGSafeSaveTests.swift
//  MachmanLabTests
//
//  L2 — Save as New VM on a live safe run: the run, its console and its vmhost go on as the
//  saved VM while the original stays as it was; the MAC the run still uses keeps the
//  original from starting without Start Anyway until the saved VM boots on its own.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport
import MachmanUI

@Suite("Save as New VM", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGSafeSaveTests {
	static let safeHeadless = StartPolicy(windowed: false, safe: true)

	@Test("6a: Save as New VM hands the live run to the new VM and leaves the original as it was")
	func saveHandsOverRun() async throws {
		try await TG.withAgent { agent in
			let data = TGDisk(name: "data", mib: 64)
			let vm = try await TGVM.alpine(
				"tg-deb", disks: [data], policy: Self.safeHeadless, on: agent)
			let kept = TGVM("tg-deb-kept", on: agent)
			let before = try await TG.dirDigest(vm.dir)
			try await vm.start(try await vm.info().startOptions(.plain))
			let host = try await vm.hostPID()
			let guest = try await vm.guest()
			defer { guest.console.close() }
			let run = "run-" + TG.nonce()
			try await guest.set("TGWHO", run)
			let marker = "TG6-" + TG.nonce()
			try await guest.loadBlockDriver(count: 1)
			let device = try await guest.device(sectors: data.sectors)
			try await guest.writeMarker(marker, device: device, sector: 8)
			let saved = try await agent.api.safeSave(vm: "tg-deb", to: "tg-deb-kept")
			try vm.handOverPid(to: kept)
			#expect(saved.name == "tg-deb-kept")
			#expect(saved.state == .running)
			// The original is stopped and plain; the saved VM runs, no longer safe.
			let original = try await vm.info()
			#expect(original.state == .stopped)
			#expect(original.safeRun != true)
			let keptInfo = try await kept.info()
			#expect(keptInfo.state == .running)
			#expect(keptInfo.safeRun != true)
			let manager = FileManager.default
			#expect(manager.fileExists(atPath: kept.dir + "/config"))
			#expect(manager.fileExists(atPath: kept.dir + "/data.raw"))
			#expect(await TG.waitForNoRunRoots(agent.scope).isEmpty)
			// T31: the original's folder is byte-identical, its config included.
			#expect(try await TG.dirDigest(vm.dir) == before)
			// The same console, the same shell: the run goes on.
			#expect(try await guest.value(of: "TGWHO") == run)
			// …served on the saved VM's socket by the same vmhost; the original's is free.
			#expect(await TG.socketPeer(kept.socketPath) == host)
			#expect(await !TG.isSocketLive(vm.socketPath))
			guest.console.close()
			try await kept.forceStop()
			#expect(await TG.waitForExit(host))
			#expect(await TG.waitForSocket(kept.socketPath, live: false, timeout: .seconds(10)))
			// The run's write is the saved VM's; the original's disk never had it.
			#expect(try TG.bytes(kept.dir + "/data.raw", offset: 4096, count: marker.count)
				== Data(marker.utf8))
			#expect(try TG.bytes(vm.dir + "/data.raw", offset: 4096, count: marker.count)
				!= Data(marker.utf8))
		}
	}

	@Test("8: the original needs Start Anyway until the saved VM boots on its new MAC")
	func originalNeedsForceUntilReboot() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("tg-r8", policy: Self.safeHeadless, on: agent)
			let kept = TGVM("tg-r8-kept", on: agent)
			try await vm.start(try await vm.info().startOptions(.plain))
			_ = try await agent.api.safeSave(vm: "tg-r8", to: "tg-r8-kept")
			try vm.handOverPid(to: kept)
			// The saved run still uses the original's MAC: a plain start is refused…
			let refused = try await vm.startError(StartOptions(openWindow: false))
			#expect(refused?.code == .macConflict)
			// …and Start Anyway (force) starts it.
			try await vm.start(StartOptions(openWindow: false, force: true))
			try await vm.forceStop()
			// The saved VM's guest reboots. VZ resets this kernel-booted guest in place: the
			// run, its vmhost and the original's MAC go on, so the original still needs
			// Start Anyway (T27). A reboot that ends the run instead ends it here too.
			let host = try await kept.hostPID()
			do {
				let guest = try await kept.guest()
				defer { guest.console.close() }
				try guest.reboot()
				// A run that ends closes the console at once; a reset boots to LAB-READY.
				let reset = (try? await guest.console.expect(
					"LAB-READY", timeout: .seconds(30))) != nil
				let how = reset ? "reset in place" : "ended its run"
				MachmanLogger.log(.log, "lab: tg-r8-kept's reboot " + how)
				if reset {
					#expect(try await kept.hostPID() == host)
					let still = try await vm.startError(StartOptions(openWindow: false))
					#expect(still?.code == .macConflict)
					guest.console.close()
					try await kept.forceStop()
				} else {
					try await kept.stopped(host: host)
				}
			}
			// Started again, the saved VM boots on its own (regenerated) MAC.
			try await kept.start(StartOptions(openWindow: false))
			let keptMAC = try await kept.info().macAddress
			let originalMAC = try await vm.info().macAddress
			#expect(keptMAC != nil && keptMAC != originalMAC)
			// Booted on its own MAC, it no longer holds the original's: no force needed.
			try await vm.start(StartOptions(openWindow: false))
			#expect(try await vm.info().state == .running)
			try await vm.forceStop()
			try await kept.forceStop()
		}
	}

	@Test("W2-17: the console tab follows the saved run; the original's console shows its own boot")
	func consoleTabFollowsSavedRun() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("tg-w217", policy: Self.safeHeadless, on: agent)
			let kept = TGVM("tg-w217-kept", on: agent)
			try await Self.consoleFollowsSave(vm: vm, kept: kept, agent: agent)
			try await kept.forceStop()
			try await vm.forceStop()
		}
	}

	// W2-17 on the desktop's own view model and terminal registry (T17).
	@MainActor
	static func consoleFollowsSave(vm: TGVM, kept: TGVM, agent: LabAgent) async throws {
		let desktop = try await TGDesktop.make(api: agent.api, scope: agent.scope, showing: vm.name)
		let model = try #require(desktop.viewModel)
		model.startPolicyDriven(try #require(desktop.vm(vm.name)), .plain)
		try #require(await desktop.waitFor(vm.name, .running))
		#expect(desktop.vm(vm.name)?.safeRun == true)
		try vm.fileHostPid(try await vm.hostPID())
		let tab = try await desktop.openConsole(vm: vm.name)
		let console = try await tab.console()
		defer { console.close() }
		let guest = try await TGGuest.ready(console)
		let run = "run-" + TG.nonce()
		try await guest.set("TGWHO", run)
		// Save as New VM from the desktop: the tab and its session go with the run.
		model.safeSave(vm.name, to: kept.name)
		try #require(await eventually(timeout: .seconds(30)) { model.selectedName == kept.name })
		try vm.handOverPid(to: kept)
		let ref = SerialPortRef(kind: .console, index: 0)
		#expect(desktop.terminals.controller(vm: kept.name, ref: ref) === tab)
		#expect(desktop.terminals.controller(vm: vm.name, ref: ref) == nil)
		#expect(tab.connected)
		#expect(tab.connectedPaths.count == 1)
		#expect(try await guest.value(of: "TGWHO") == run)
		// The original: Start meets the MAC the run still uses and offers Start Anyway.
		try #require(await desktop.waitFor(vm.name, .stopped))
		model.startPolicyDriven(try #require(desktop.vm(vm.name)), .plain)
		try #require(await eventually(timeout: .seconds(30)) { model.pendingForceStart != nil })
		let pending = try #require(model.pendingForceStart)
		#expect(pending.name == vm.name)
		#expect(pending.safe)
		#expect(model.presentedError == nil)
		model.startVM(pending.name, headless: pending.headless, force: true, safe: pending.safe)
		model.pendingForceStart = nil
		try #require(await desktop.waitFor(vm.name, .running))
		try vm.fileHostPid(try await vm.hostPID())
		// Its console tab is a new session that shows its own boot, not the saved run.
		let fresh = try await desktop.openConsole(vm: vm.name)
		#expect(fresh !== tab)
		let freshConsole = try await fresh.console()
		defer { freshConsole.close() }
		let other = try await TGGuest.ready(freshConsole)
		#expect(try await other.value(of: "TGWHO") == "unset")
		let seen = String(decoding: tab.transcript(), as: UTF8.self)
		#expect(seen.components(separatedBy: "LAB-READY").count - 1 == 1)
	}
}
