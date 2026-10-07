//
//  KernelSectionsFlowTests.swift
//  MachmanDesktopCoreTests
//
//  The user's review-4 note, end to end over the stub (which acts like the engine since Q29):
//  picking Kernel Boot and switching back, with no kernel ever added, left the device tree's
//  Kernel and Initramfs sections in place, dimmed, with nothing to remove them (N3).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct KernelSectionsFlowTests {
	@Test("N3: a VM switched to kernel boot and back with no kernel set shows no kernel sections")
	func kernelBootOnAndOffLeavesNoSections() async {
		let h = await DesktopHarness.make()
		func debian() -> VMInfo? { h.viewModel.vms.first { $0.name == "Debian" } }
		#expect(debian()?.showsKernelSections == false)
		#expect(await h.viewModel.setKernelBoot("Debian", enabled: true))
		#expect(await eventually { debian()?.boot.mode == .linuxKernel })
		#expect(debian()?.showsKernelSections == true)   // its add path while kernel boot is on
		#expect(await h.viewModel.setKernelBoot("Debian", enabled: false))
		#expect(await eventually { debian()?.boot.mode == .efi })
		// Fails until the open bug N3 (an empty kernel draft keeps the parked sections) is fixed.
		#expect(debian()?.showsKernelSections == false)
	}
}
