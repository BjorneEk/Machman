//
//  KernelClearFlowTests.swift
//  MachmanDesktopCoreTests
//
//  Remove Kernel Settings… (H54, K2, the user's review-4 note): a kernel draft kept after
//  kernel boot was switched off had no single way out. The parked Kernel label and the Kernel
//  inspector now ask once and remove the draft, the VM's kernel files and their overrides in
//  one daemon call, for a draft holding only a command line (K1) and on a macOS VM (K3) too.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct KernelClearFlowTests {
	private func vm(_ h: DesktopHarness, _ name: String) -> VMInfo? {
		h.viewModel.vms.first { $0.name == name }
	}

	@Test("H54: Remove Kernel Settings asks once, then the draft and its sections go")
	func removeAsksThenClears() async throws {
		let h = await DesktopHarness.make([Samples.kernelParked()])
		let lab = try #require(vm(h, "Kernel Lab"))
		#expect(lab.offersKernelClear)
		h.viewModel.select(name: "Kernel Lab")
		h.viewModel.treeSelection = [.group("Kernel")]
		h.viewModel.requestClearKernelSettings(lab)
		let pending = try #require(h.viewModel.pendingKernelClear)
		#expect(pending.title == "Remove Kernel Lab’s kernel settings and its 3 kernel files?")
		#expect(pending.message
			== "The files belong to Kernel Lab and are removed from its directory.")
		#expect(!h.stub.calls.contains("clearKernelSettings"))   // asked, nothing sent yet

		h.viewModel.clearKernelSettings(pending.vm)
		#expect(await eventually { self.vm(h, "Kernel Lab")?.showsKernelSections == false })
		#expect(h.stub.calls.filter { $0 == "clearKernelSettings" }.count == 1)
		#expect(vm(h, "Kernel Lab")?.boot.mode == .efi)
		#expect(await eventually { h.viewModel.treeSelection.isEmpty })
		#expect(await eventually {
			h.viewModel.toasts.contains { $0.message == "Removed kernel settings" }
		})
	}

	// K1: a command line is something kept, so a draft holding only one shows parked and is
	// removable; the question then names no files.
	@Test("H54: a parked draft holding only a command line is removable")
	func aCommandLineOnlyDraftIsRemovable() async throws {
		let h = await DesktopHarness.make([Samples.kernelParkedCommandLineOnly()])
		let lab = try #require(vm(h, "Kernel Lab"))
		#expect(lab.offersKernelClear)
		h.viewModel.requestClearKernelSettings(lab)
		let pending = try #require(h.viewModel.pendingKernelClear)
		#expect(pending.title == "Remove Kernel Lab’s kernel settings?")
		#expect(pending.message == nil)
		h.viewModel.clearKernelSettings(pending.vm)
		#expect(await eventually { self.vm(h, "Kernel Lab")?.showsKernelSections == false })
	}

	// K3: a macOS VM keeps the kernel files of its kernel-boot past, deletable; removing them
	// leaves it a macOS VM.
	@Test("D31: a macOS VM's kernel files go with Remove Kernel Settings")
	func aMacOSVMsKernelFilesGo() async throws {
		let h = await DesktopHarness.make([Samples.macOSWithKernelFiles()])
		let mac = try #require(vm(h, "Sequoia"))
		#expect(mac.showsKernelSections && mac.offersKernelClear)
		h.viewModel.requestClearKernelSettings(mac)
		#expect(h.viewModel.pendingKernelClear?.title
			== "Remove Sequoia’s kernel settings and its 3 kernel files?")
		h.viewModel.clearKernelSettings("Sequoia")
		#expect(await eventually { self.vm(h, "Sequoia")?.showsKernelSections == false })
		#expect(vm(h, "Sequoia")?.boot.mode == .macOS)
	}

	// An older Machman Agent answers vm.kernel.clear with -32601 (read as unsupported): the
	// alert says what to do, never "unknown method 'vm.kernel.clear'".
	@Test("H54: an older Machman Agent's answer says to update it")
	func anOlderAgentSaysToUpdate() async throws {
		let h = await DesktopHarness.make([Samples.kernelParked()])
		h.stub.fail(
			"clearKernelSettings",
			with: MachmanError(code: .unsupported, message: "unknown method 'vm.kernel.clear'"))
		h.viewModel.clearKernelSettings("Kernel Lab")
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.presentedError?.title == "Removing kernel settings failed")
		#expect(h.viewModel.presentedError?.message
			== VMListViewModel.kernelClearNeedsNewerAgent)
		#expect(vm(h, "Kernel Lab")?.showsKernelSections == true)
	}

	// Offered only on parked sections: never while kernel boot reads the draft, nor in a boot
	// mode a newer Machman wrote.
	@Test("H54: Remove Kernel Settings is offered only on a parked draft")
	func offeredOnlyWhileParked() {
		#expect(!Samples.kernelBoot().offersKernelClear)
		#expect(!Samples.linux().offersKernelClear)
		var newer = Samples.kernelParked()
		newer.boot.mode = .unknown
		#expect(!newer.offersKernelClear)
		#expect(Samples.kernelParked().offersKernelClear)
	}
}
