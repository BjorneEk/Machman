//
//  DockMenuTests.swift
//  MachmanDesktopCoreTests
//
//  The Dock's start/stop items (P21): a Start follows the VM's start policy like every other
//  Start, the item is off during a macOS install and while no view model is connected, and a
//  running VM's item shuts it down — as does the item of a VM whose state is unknown (C15).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct DockMenuTests {
	// The old Dock sent (openWindow: true, safe: false) whatever the policy.
	@Test func theDockStartsASafePolicyVMSafely() async {
		var vm = Samples.linux("Alpine")
		vm.startPolicy = StartPolicy(windowed: false, safe: true)
		let h = await DesktopHarness.make([vm])
		h.viewModel.performDockItem(vm: "Alpine")
		#expect(await eventually { h.stub.starts.count == 1 })
		#expect(h.stub.starts.first?.options == StartOptions(openWindow: false, safe: true))
	}

	@Test func theDockItemIsOffDuringAnInstall() async throws {
		let h = await DesktopHarness.make()
		let sequoia = try #require(h.viewModel.vms.first { $0.name == "Sequoia" })
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: InstallPhase(kind: .installing)))
		#expect(await eventually { h.viewModel.isInstalling(sequoia) })
		let item = VMListViewModel.dockMenuItems(vms: h.viewModel.vms, viewModel: h.viewModel)
			.first { $0.vm == "Sequoia" }
		#expect(item?.title == "Start Sequoia")
		#expect(item?.enabled == false)
		h.viewModel.performDockItem(vm: "Sequoia")
		#expect(await h.settled())
		#expect(h.stub.starts.isEmpty)
	}

	@Test func dockItemsWaitForAConnection() {
		let items = VMListViewModel.dockMenuItems(vms: Samples.library(), viewModel: nil)
		#expect(items.map(\.title) == [
			"Shut Down Debian", "Start Sequoia", "Shut Down Kernel Lab", "Start Fedora",
			"Start Alpine",
		])
		#expect(items.allSatisfy { !$0.enabled })
	}

	@Test func aRunningVMsItemShutsItDown() async {
		let h = await DesktopHarness.make()
		let item = VMListViewModel.dockMenuItems(vms: h.viewModel.vms, viewModel: h.viewModel)
			.first { $0.vm == "Debian" }
		#expect(item?.title == "Shut Down Debian")
		#expect(item?.running == true)
		#expect(item?.enabled == true)
		h.viewModel.performDockItem(vm: "Debian")
		#expect(await eventually { h.stub.calls.contains("stop") })
		#expect(h.stub.starts.isEmpty)
	}

	// Machman Agent hasn't reached its vmhost: busy, so Shut Down (before: "Start Debian",
	// which the agent refused).
	@Test func anUnknownVMsItemShutsItDown() async {
		let h = await DesktopHarness.make(Samples.libraryWithUnreachedHost())
		let item = VMListViewModel.dockMenuItems(vms: h.viewModel.vms, viewModel: h.viewModel)
			.first { $0.vm == "Debian" }
		#expect(item?.title == "Shut Down Debian")
		#expect(item?.running == true)
		#expect(item?.enabled == true)
		h.viewModel.performDockItem(vm: "Debian")
		#expect(await eventually { h.stub.calls.contains("stop") })
		#expect(h.stub.starts.isEmpty)
	}
}
