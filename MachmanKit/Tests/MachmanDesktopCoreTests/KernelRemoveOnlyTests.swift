//
//  KernelRemoveOnlyTests.swift
//  MachmanDesktopCoreTests
//
//  A macOS VM's kernel sections only remove what it kept from before its switch (D31): the
//  tree's background Paste and Edit ▸ Paste reached EntityClipboard.paste and imported a
//  copied kernel anyway (review F20). They skip kernel files for a macOS VM now, and say so.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct KernelRemoveOnlyTests {
	private static let kernels = "\(Samples.vmsRoot)/Kernel Lab/kernels"

	@Test("D31: pasting kernel files into a macOS VM sends no promote and says why")
	func pastingKernelsIntoAMacOSVMSkipsThem() async throws {
		let h = await DesktopHarness.make([Samples.macOS("Sequoia"), Samples.linux("Debian")])
		let kernel = EntityClipboard(kind: .kernel, path: Self.kernels + "/kernel/6.12/vmlinuz")
		let initrd = EntityClipboard(
			kind: .initramfs, path: Self.kernels + "/initramfs/6.12/initrd.img")
		let mount = EntityClipboard(kind: .mount, path: "/Users/demo/notes", tag: "notes")
		AddFlows.paste(
			entities: [kernel, initrd, mount], fileURLs: [], into: "Sequoia",
			viewModel: h.viewModel)
		#expect(await eventually { h.stub.calls.contains("addMount") })
		#expect(await eventually {
			h.viewModel.toasts.contains {
				$0.message == "Skipped 2 kernel files \u{2014} Sequoia is a macOS VM"
			}
		})
		#expect(!h.stub.calls.contains("promoteKernelFile"))
		#expect(EntityClipboard.skippedKernels(1, vm: "Sequoia")
			== "Skipped a kernel file \u{2014} Sequoia is a macOS VM")

		// An EFI VM takes them as before.
		AddFlows.paste(entities: [kernel], fileURLs: [], into: "Debian", viewModel: h.viewModel)
		#expect(await eventually { h.stub.calls.contains("promoteKernelFile") })
	}
}
