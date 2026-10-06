//
//  KernelSettingsCommitTests.swift
//  MachmanDesktopCoreTests
//
//  P41: vm.kernel.update replaces a VM's whole kernel settings, so a write built from an
//  older copy of them undoes whatever changed since. The command line's debounced commit
//  landed 600 ms after the render it was built from and reverted a kernel picked meanwhile;
//  two picks made from one render reverted each other. Every write starts from the VM's
//  current settings instead.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct KernelSettingsCommitTests {
	@Test("P41: a command-line commit keeps a kernel picked while it waited")
	func writesStartFromTheCurrentSettings() async throws {
		let h = await DesktopHarness.make([Samples.kernelBoot()])
		let stale = h.viewModel.vms[0]
		let kernels = stale.boot.ownedKernels ?? []
		let lts = try #require(kernels.first { $0.tag == "6.6-lts" }).path
		let line = "console=hvc0 root=/dev/vda2 quiet"

		// Two picks from one render: the initramfs pick must not undo the kernel pick.
		h.viewModel.setActiveKernelFile(stale, role: .kernel, path: lts)
		#expect(await eventually { h.viewModel.vms[0].boot.kernel?.kernelPath == lts })
		h.viewModel.setActiveKernelFile(stale, role: .initramfs, path: nil)
		#expect(await eventually { h.stub.kernelSettingsSent.count == 2 })
		#expect(h.stub.kernelSettingsSent.last?.settings.kernelPath == lts)
		#expect(await eventually { h.viewModel.vms[0].boot.kernel?.initrdPath == nil })

		// The editor's commit names only the VM: the rest comes from what is served now.
		h.viewModel.setKernelCommandLine("Kernel Lab", line)
		#expect(await eventually { h.stub.kernelSettingsSent.count == 3 })
		let sent = try #require(h.stub.kernelSettingsSent.last?.settings)
		#expect(sent.kernelPath == lts)
		#expect(sent.initrdPath == nil)
		#expect(sent.commandLine == line)

		// The line served back, an unchanged one sends nothing.
		#expect(await eventually { h.viewModel.vms[0].boot.kernel?.commandLine == line })
		h.viewModel.setKernelCommandLine("Kernel Lab", line)
		try await Task.sleep(for: .milliseconds(100))
		#expect(h.stub.kernelSettingsSent.count == 3)
	}
}
