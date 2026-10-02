//
//  SetEnabledDevicesTests.swift
//  MachmanTests
//
//  A13: vm.setEnabled covers devices too (1.0.12), keyed by kind, with the batch's
//  all-or-nothing rule — a kind the VM doesn't have refuses every flag in the call. Engine
//  half on a real VMConfig under a redirected data dir; wire half end to end over a socket.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct SetEnabledDevicesTests {
	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	@Test func aDeviceFlagRidesTheBatch() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("alpha")
			#expect(vm.devices.contains { $0.kind == DeviceKind.network.rawValue })
			try vm.setEnabled(
				disks: [:], mounts: [:], console: ["0": false], uart: [:],
				devices: [DeviceKind.network.rawValue: false])
			let reloaded = try VMConfig.load(name: "alpha")
			#expect(reloaded.devices.first { $0.deviceKind == .network }?.enabled == false)
			let enabledCount = reloaded.devices.filter(\.enabled).count
			#expect(enabledCount == reloaded.devices.count - 1)
			#expect(reloaded.consolePorts.first?.enabled == false)
		}
	}

	@Test func anAbsentDeviceRefusesTheWholeBatch() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("beta")
			// EFI VMs carry no trackpad (it needs macOS boot).
			#expect(!vm.devices.contains { $0.deviceKind == .trackpad })
			#expect(throws: MachmanError.self) {
				try vm.setEnabled(
					disks: [:], mounts: [:], console: ["0": false], uart: [:],
					devices: [DeviceKind.network.rawValue: false,
						DeviceKind.trackpad.rawValue: false])
			}
			let reloaded = try VMConfig.load(name: "beta")
			#expect(reloaded.consolePorts.first?.enabled == true)
			let allEnabled = reloaded.devices.allSatisfy(\.enabled)
			#expect(allEnabled)
		}
	}

	@Test @MainActor func overTheWire() async throws {
		let socketPath = TestEnvironment.socketPath("mm-enable")
		let stub = StubMachman()
		var debian = StubMachman.makeInfo("Debian")
		debian.devices = [DeviceInfo(kind: .network), DeviceInfo(kind: .entropy)]
		stub.vms["Debian"] = debian
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "a13")

		try await client.setEnabled(
			vm: "Debian", disks: nil, mounts: nil, console: nil, uart: nil,
			devices: [DeviceKind.network.rawValue: false])
		#expect(stub.vms["Debian"]?.devices?.first { $0.kind == .network }?.enabled == false)
		#expect(stub.vms["Debian"]?.devices?.first { $0.kind == .entropy }?.enabled == true)

		await #expect(throws: MachmanError.self) {
			try await client.setEnabled(
				vm: "Debian", disks: nil, mounts: nil, console: nil, uart: nil,
				devices: [DeviceKind.trackpad.rawValue: false])
		}
	}
}
