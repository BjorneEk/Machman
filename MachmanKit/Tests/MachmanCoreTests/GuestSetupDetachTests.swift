//
//  GuestSetupDetachTests.swift
//  MachmanTests
//
//  D12: removing Guest Setup from a RUNNING VM (the vmhost serves the call) leaves the
//  served share for teardown — the vm.setup.serve-off rule; a stopped VM drops it at once.
//  A bare VMRuntime (no VZ) marks the VM running, the PromoteRestrictedVMTests way.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct GuestSetupDetachTests {
	@Test @MainActor func aRunningGuestKeepsItsShareUntilTeardown() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let share = GuestInstallerWriter.payloadRoot(for: vm.config).path
			let fm = FileManager.default

			try api.attachDevice(.guestSetup, to: vm)
			_ = try GuestSetupInstaller.writePayload(for: vm.config)   // the start's write
			vm.runtime = VMRuntime(config: vm.config, events: registry.events)
			try api.detachDevice(.guestSetup, from: vm)
			#expect(!vm.config.devices.contains { $0.deviceKind == .guestSetup })
			#expect(fm.fileExists(atPath: share))

			vm.runtime = nil
			try api.attachDevice(.guestSetup, to: vm)
			try api.detachDevice(.guestSetup, from: vm)
			#expect(!fm.fileExists(atPath: share))
		}
	}
}
