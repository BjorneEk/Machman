//
//  RoutingPendingStartTests.swift
//  MachmanTests
//
//  The router's start-window reservation: `hosted` is written only after the spawn (and,
//  for safe runs, a possibly minutes-long shadow build), so pendingStarts is what makes a
//  booting VM visible to every guard in the window. Exercised through the internal seam
//  (tests reserve a name directly) plus real start() calls whose spawn fails in the test
//  host — no VZ, no vmhost. Setup runs inside the redirected-dir lock (synchronous), the
//  async surface touches only in-memory state (MacConflictTests pattern).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

@MainActor
private final class HeardEvents {
	var events: [VMEvent] = []
}

struct RoutingPendingStartTests {
	@MainActor
	private func makeRouting(names: [String], mac: String? = nil) throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				if let mac { cfg.macAddress = mac }
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		return routing
	}

	// E1: the loser of two concurrent starts must be refused, never adopt-and-kill the
	// winner's half-spawned vmhost.
	@Test @MainActor func secondStartIsRefusedWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.reserveStart("pending-alpha", mac: nil)

		do {
			try await routing.start(vm: "pending-alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("already starting"))
		}
	}

	// E2: whole-VM operations must see a pending start as running — the vmhost is (or is
	// about to be) reading the very files they would move or delete.
	@Test @MainActor func guardedOpsRefuseWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.reserveStart("pending-alpha", mac: nil)

		let ops: [(String, () async throws -> Void)] = [
			("delete", { try await routing.deleteVM(named: "pending-alpha") }),
			("rename", { try await routing.renameVM(named: "pending-alpha", to: "x") }),
			("copy", { _ = try await routing.copyVM(
				vm: "pending-alpha", newName: nil, diskIDs: nil, regenerateMAC: true) }),
			("regenerateMAC", { _ = try await routing.regenerateMAC(vm: "pending-alpha") }),
			("resizeDisk", { _ = try await routing.resizeDisk(
				vm: "pending-alpha", diskID: "storage:disk", sizeBytes: 1) }),
			("removeDisk", { try await routing.removeDisk(
				vm: "pending-alpha", diskID: "storage:disk") }),
			("promoteDisk", { _ = try await routing.promoteDisk(
				vm: "pending-alpha", diskID: "storage:disk") }),
			("consoleAdd", { try await routing.addConsolePort(vm: "pending-alpha") }),
			("installStart", { try await routing.startMacInstall(
				vm: "pending-alpha", source: .latest) }),
		]
		for (label, op) in ops {
			do {
				try await op()
				Issue.record("\(label): expected invalidState while a start is pending")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState, "\(label) carried \(error.code)")
			}
		}
	}

	// E19: while a start is in flight nothing is hosted yet, and every per-VM call used to
	// land on the daemon's own config copy — which the vmhost's whole-file saves then
	// silently reverted (and vm.stop "succeeded" doing nothing). They refuse now, and reads
	// say starting instead of stopped.
	@Test @MainActor func proxiedCallsRefuseWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.reserveStart("pending-alpha", mac: nil)
		let vm = "pending-alpha"

		let ops: [(String, () async throws -> Void)] = [
			("setHardware", { try await routing.setHardware(
				vm: vm, cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil) }),
			("addDisk", { try await routing.addDisk(
				vm: vm, NewDisk(type: .storage, name: "data", sizeBytes: 1 << 20)) }),
			("importDisk", { _ = try await routing.importDisk(vm: vm, path: "/nonexistent") }),
			("addMount", { try await routing.addMount(
				vm: vm, path: "/nonexistent", tag: "docs", kind: nil) }),
			("removeMount", { try await routing.removeMount(vm: vm, mountID: "m") }),
			("setSerialLogging", { try await routing.setSerialLogging(
				vm: vm, kind: .console, index: 0, config: SerialLogConfig()) }),
			("setKernelBoot", { try await routing.setKernelBoot(vm: vm, enabled: true) }),
			("updateKernelSettings", { try await routing.updateKernelSettings(
				vm: vm, KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")) }),
			("setStartPolicy", { try await routing.setStartPolicy(vm: vm, policy: StartPolicy()) }),
			("setSafety", { try await routing.setSafety(vm: vm, disks: nil, mounts: nil) }),
			("addDevice", { _ = try await routing.addDevice(vm: vm, kind: .entropy) }),
			("updateDevice", { _ = try await routing.updateDevice(
				vm: vm, device: DeviceInfo(kind: .entropy)) }),
			("setEnabled", { try await routing.setEnabled(
				vm: vm, disks: nil, mounts: nil, console: nil, uart: nil) }),
			("setSSH", { _ = try await routing.setSSH(
				vm: vm, integrationEnabled: true, reverseApproved: nil, alias: nil) }),
			("resetSSH", { _ = try await routing.resetSSH(vm: vm) }),
			("resetSetup", { _ = try await routing.resetSetup(vm: vm) }),
			("setSetupServed", { _ = try await routing.setSetupServed(vm: vm, serve: true) }),
			("setMountTag", { _ = try await routing.setMountTag(vm: vm, mountID: "m", tag: "t") }),
			("setMountKind", { _ = try await routing.setMountKind(
				vm: vm, mountID: "m", kind: MountKind.sshfs) }),
			("stop", { try await routing.stop(vm: vm, mode: .force) }),
			("openWindow", { try await routing.openWindow(vm: vm) }),
			("closeWindow", { try await routing.closeWindow(vm: vm) }),
		]
		for (label, op) in ops {
			do {
				try await op()
				Issue.record("\(label): expected invalidState while a start is pending")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState, "\(label) carried \(error.code)")
				#expect(error.message.contains("is starting"), "\(label): \(error.message)")
			} catch {
				Issue.record("\(label): \(error)")
			}
		}
		let info = try await routing.vm(named: vm)
		#expect(info.cpuCount == 2)          // the daemon's copy was never edited
		#expect(info.state == .starting)     // never "stopped", which offered a second Start
		#expect(try await routing.listVMs().first?.state == .starting)
	}

	// The preview poller's read never errors: a VM that is starting has no preview yet.
	@Test @MainActor func previewIsNilWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.reserveStart("pending-alpha", mac: nil)
		#expect(try await routing.preview(vm: "pending-alpha", maxWidth: nil) == nil)
	}

	// The reservation must be released when a start throws after claiming the name —
	// here at the MAC-conflict guard (first throw site past the insert).
	@Test @MainActor func reservationIsReleasedWhenTheStartIsRefused() async throws {
		let mac = "aa:bb:cc:77:11:22"
		let routing = try makeRouting(names: ["pending-alpha", "pending-beta"], mac: mac)

		let socketPath = TestEnvironment.socketPath("mm-pend")
		let stub = StubMachman()
		stub.vms["pending-alpha"] = StubMachman.makeInfo("pending-alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await routing.connectHost(identity: RoutingMachman.HostIdentity(
			id: UUID(), name: "pending-alpha", socketPath: socketPath))
		routing.adopt(
			identity: RoutingMachman.HostIdentity(
				id: UUID(), name: "pending-alpha", socketPath: socketPath, macInUse: mac),
			client: client)

		do {
			try await routing.start(vm: "pending-beta", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
		}
		#expect(routing.pendingStarts.isEmpty)
		#expect(routing.pendingStartMACs.isEmpty)
		await client.disconnect()
	}

	// E19's MAC half: a start still in its spawn window (nothing hosted yet) holds its MAC
	// too — two same-MAC VMs started together used to both boot, and one lost networking.
	@Test @MainActor func aStartingVMsMACBlocksASecondStart() async throws {
		let mac = "aa:bb:cc:77:33:44"
		let routing = try makeRouting(names: ["pending-alpha", "pending-beta"], mac: mac)
		routing.reserveStart("pending-alpha", mac: mac)

		do {
			try await routing.start(vm: "pending-beta", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
			#expect(error.message.contains("pending-alpha"))
			#expect(error.message.contains("starting"))
		}
		#expect(routing.pendingStartMACs.keys.sorted() == ["pending-alpha"])
	}

	@Test @MainActor func forceBypassesAStartingVMsMAC() async throws {
		let mac = "aa:bb:cc:77:55:66"
		let routing = try makeRouting(names: ["pending-alpha", "pending-beta"], mac: mac)
		routing.reserveStart("pending-alpha", mac: mac)

		do {
			try await routing.start(vm: "pending-beta", options: StartOptions(force: true))
			Issue.record("expected a spawn failure in the test host")
		} catch let error as MachmanError {
			#expect(error.code != .macConflict)   // past the guard, failing at the spawn
		}
	}

	// The earlier reservation wins: the later start is the one refused, never both.
	@Test @MainActor func aLaterReservationNeverBlocksAnEarlierOne() async throws {
		let mac = "aa:bb:cc:77:77:88"
		let routing = try makeRouting(names: ["pending-alpha", "pending-beta"], mac: mac)
		routing.reserveStart("pending-beta", mac: mac)

		do {
			try await routing.start(vm: "pending-alpha", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
			#expect(error.message.contains("pending-beta"))
		}
		routing.releaseStart("pending-beta")
		#expect(routing.pendingStartMACs.isEmpty)
		#expect(routing.pendingStarts.isEmpty)

		// Both in flight at once: the earlier passes, only the later is refused.
		routing.reserveStart("pending-alpha", mac: mac)
		routing.reserveStart("pending-beta", mac: mac)
		#expect(throws: Never.self) {
			try routing.checkMACConflict(name: "pending-alpha", mac: mac, options: StartOptions())
		}
		#expect(throws: MachmanError.self) {
			try routing.checkMACConflict(name: "pending-beta", mac: mac, options: StartOptions())
		}
	}

	// …and when it fails deeper in: past purge and probe, at the spawn itself (the test
	// host embeds no MachmanVMHost.app, so the spawn path is the failure).
	@Test @MainActor func reservationIsReleasedWhenTheSpawnFails() async throws {
		let routing = try makeRouting(names: ["pending-gamma"])

		do {
			try await routing.start(vm: "pending-gamma", options: StartOptions())
			Issue.record("expected a spawn failure in the test host")
		} catch let error as MachmanError {
			#expect(error.code == .internalError)
		}
		#expect(routing.pendingStarts.isEmpty)
		#expect(routing.hostedNames.isEmpty)
	}

	// The VM listed as starting while the start ran: a failed start says it no longer is, or a
	// client that lists on listChanged keeps showing it starting.
	@Test @MainActor func aFailedStartAnnouncesTheList() async throws {
		let routing = try makeRouting(names: ["pending-delta"])
		let heard = HeardEvents()
		let stream = await routing.events()
		let pump = Task { @MainActor in
			for await event in stream { heard.events.append(event) }
		}
		defer { pump.cancel() }

		await #expect(throws: MachmanError.self) {
			try await routing.start(vm: "pending-delta", options: StartOptions())
		}
		// Before: nothing announced it.
		#expect(await eventually { heard.events.contains(.listChanged) })
		#expect(try await routing.vm(named: "pending-delta").state == .stopped)
	}

	// C11: a boot mode a newer Machman wrote is refused before anything is spawned — a vmhost
	// launched for it would only refuse in turn, a Dock icon that flashes and goes.
	@Test @MainActor func aNewerBootModeIsRefusedBeforeASpawn() async throws {
		let routing = try makeRouting(names: ["pending-newer"])
		let vm = try #require(routing.registry.vm(named: "pending-newer"))
		vm.config.boot = try JSONDecoder().decode(
			BootConfig.self, from: Data(#"{"future":{"_0":{}}}"#.utf8))
		var located = 0
		routing.locateVMHost = {
			located += 1
			return nil
		}

		do {
			try await routing.start(vm: "pending-newer", options: StartOptions())
			Issue.record("expected the newer boot mode's refusal")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "A newer version of Machman set this VM\u{2019}s boot mode")
		}
		#expect(located == 0)   // before: the start went on to locate a vmhost to launch
		#expect(routing.pendingStarts.isEmpty)
	}
}
