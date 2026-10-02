//
//  RoutingVersionFloorTests.swift
//  MachmanTests
//
//  E22 (decision 9): a VM still running under a vmhost older than the daemon runs old code —
//  its decoder drops config keys the newer clients rely on (Capture System Keys snapped back
//  to Off after a Replace). Its setting changes are refused with "Restart … to finish
//  updating" until it restarts under a current vmhost; everything that is not a setting
//  change (stop, window, preview) keeps working, and the list marks the VM. A vmhost that
//  reports no usable version (a launch-agent host from before vmhosts read their own bundle
//  version reports "dev-vmhost") counts as older.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingVersionFloorTests {
	@MainActor
	private func makeRouting(daemonVersion: String = "1.0.12") throws -> (RoutingMachman, String) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: daemonVersion)
			routing.locateVMHost = { nil }
		}
		let socketPath = TestEnvironment.socketPath("mm-floor")
		routing.socketPathForVM = { _ in socketPath }
		routing.helloDeadline = .seconds(10)
		routing.hostProbeDeadline = .seconds(10)
		return (routing, socketPath)
	}

	// A running VM's vmhost, answering hello with `version`.
	@MainActor
	private func serveHost(at socketPath: String, version: String) throws
		-> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: version)
		try startServing(server)
		return (stub, server)
	}

	@Test(arguments: ["1.0.11-vmhost", "dev-vmhost"])
	@MainActor func anOlderVMHostRefusesSettingChanges(_ version: String) async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveHost(at: socketPath, version: version)
		defer { server.stop() }

		await #expect(throws: MachmanError.self) {
			try await routing.setHardware(
				vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
		}
		#expect(!stub.calls.contains("setHardware"))
		#expect(stub.vms["alpha"]?.cpuCount == 2)
	}

	@Test @MainActor func everySettingChangeRefuses() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveHost(at: socketPath, version: "1.0.11-vmhost")
		defer { server.stop() }
		let vm = "alpha"

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
			("promoteKernelFile", { _ = try await routing.promoteKernelFile(
				vm: vm, role: .kernel, sourcePath: "/nonexistent", tag: "t") }),
			("deleteKernelFile", { _ = try await routing.deleteKernelFile(
				vm: vm, path: "/nonexistent") }),
			("setStartPolicy", { try await routing.setStartPolicy(vm: vm, policy: StartPolicy()) }),
			("setSafety", { try await routing.setSafety(vm: vm, disks: nil, mounts: nil) }),
			("addDevice", { _ = try await routing.addDevice(vm: vm, kind: .entropy) }),
			("removeDevice", { _ = try await routing.removeDevice(vm: vm, kind: .entropy) }),
			("updateDevice", { _ = try await routing.updateDevice(
				vm: vm, device: DeviceInfo(kind: .entropy)) }),
			("setEnabled", { try await routing.setEnabled(
				vm: vm, disks: nil, mounts: nil, console: ["0": false], uart: nil) }),
			("setKernelOverride", { _ = try await routing.setKernelOverride(
				vm: vm, path: "/nonexistent", commandLine: "quiet", overrideEnabled: true) }),
			("setMountTag", { _ = try await routing.setMountTag(vm: vm, mountID: "m", tag: "t") }),
			("setMountKind", { _ = try await routing.setMountKind(
				vm: vm, mountID: "m", kind: MountKind.sshfs) }),
			("setSSH", { _ = try await routing.setSSH(
				vm: vm, integrationEnabled: true, reverseApproved: nil, alias: nil) }),
			("resetSSH", { _ = try await routing.resetSSH(vm: vm) }),
			("resetSetup", { _ = try await routing.resetSetup(vm: vm) }),
			("setSetupServed", { _ = try await routing.setSetupServed(vm: vm, serve: true) }),
		]
		#expect(ops.count == 23)
		for (label, op) in ops {
			do {
				try await op()
				Issue.record("\(label): expected the outdated vmhost to refuse")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState, "\(label) carried \(error.code)")
				#expect(error.message == "Restart alpha to finish updating", "\(label)")
			} catch {
				Issue.record("\(label): \(error)")
			}
		}
		let reached = Set(stub.calls).intersection(ops.map(\.0))
		#expect(reached.isEmpty, "reached the old vmhost: \(reached.sorted())")
	}

	@Test @MainActor func theRefusalSaysToRestart() async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try serveHost(at: socketPath, version: "1.0.11-vmhost")
		defer { server.stop() }
		do {
			try await routing.setEnabled(
				vm: "alpha", disks: nil, mounts: nil, console: ["0": false], uart: nil)
			Issue.record("expected the outdated vmhost to refuse")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "Restart alpha to finish updating")
		}
	}

	@Test @MainActor func aCurrentVMHostTakesSettingChanges() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveHost(at: socketPath, version: "1.0.12-vmhost")
		defer { server.stop() }

		try await routing.setHardware(
			vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
		#expect(stub.vms["alpha"]?.cpuCount == 3)
	}

	@Test @MainActor func anOutdatedVMHostStillStopsAndOpensItsWindow() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveHost(at: socketPath, version: "dev-vmhost")
		defer { server.stop() }

		try await routing.openWindow(vm: "alpha")
		try await routing.closeWindow(vm: "alpha")
		_ = try await routing.preview(vm: "alpha", maxWidth: nil)
		try await routing.stop(vm: "alpha", mode: .soft)
		for call in ["openWindow", "closeWindow", "preview", "stop"] {
			#expect(stub.calls.contains(call), "\(call) did not reach the vmhost")
		}
	}

	@Test(arguments: [("1.0.11-vmhost", true), ("1.0.12-vmhost", false)])
	@MainActor func theListMarksAnOutdatedVMHost(_ version: String, _ outdated: Bool)
		async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try serveHost(at: socketPath, version: version)
		defer { server.stop() }

		_ = try await routing.listVMs()   // adopts the late host
		#expect(await eventually { routing.hostedNames == ["alpha"] })
		let alpha = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(alpha?.outdatedHost == (outdated ? true : nil))
	}

	// A daemon without a version of its own ("test", "dev") has no floor to apply.
	@Test @MainActor func anUnversionedDaemonAppliesNoFloor() async throws {
		let (routing, socketPath) = try makeRouting(daemonVersion: "test")
		let (stub, server) = try serveHost(at: socketPath, version: "dev-vmhost")
		defer { server.stop() }

		try await routing.setHardware(
			vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
		#expect(stub.vms["alpha"]?.cpuCount == 3)
	}
}
