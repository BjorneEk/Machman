//
//  CopyMountsTests.swift
//  MachmanDesktopCoreTests
//
//  C11: Duplicate… sends the mounts the user kept. Every mount ticked sends no list (every
//  mount travels — the request an older daemon knows), an unticked one is left out.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct CopyMountsTests {
	@Test func anUntickedMountStaysBehind() async throws {
		let vm = Samples.linuxWithMounts()
		let h = await DesktopHarness.make([vm])
		let kept = try #require(vm.mounts.first?.id)
		let mountIDs = VMListViewModel.copyMountIDs(for: vm, included: [kept])
		#expect(mountIDs == [kept])

		#expect(h.viewModel.submitCopy(
			vm, name: "Debian copy", diskIDs: ["storage:system"], mountIDs: mountIDs))
		#expect(await eventually { h.viewModel.selectedName == "Debian copy" })
		#expect(h.stub.copies.last?.mountIDs == [kept])
		#expect(h.stub.vms["Debian copy"]?.mounts.map(\.id) == [kept])
	}

	@Test func everyMountTickedSendsNoList() async {
		let vm = Samples.linuxWithMounts()
		#expect(VMListViewModel.copyMountIDs(for: vm, included: Set(vm.mounts.map(\.id))) == nil)
		#expect(VMListViewModel.copyMountIDs(for: Samples.macOS(), included: []) == nil)

		let h = await DesktopHarness.make([vm])
		#expect(h.viewModel.submitCopy(vm, name: "Debian copy", diskIDs: []))
		#expect(await eventually { h.stub.copies.count == 1 })
		#expect(h.stub.copies.last?.mountIDs == nil)
		#expect(await eventually { h.stub.vms["Debian copy"]?.mounts.count == 2 })
	}
}
