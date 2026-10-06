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

	// Review F8 (wave r3w3): a served copy lags each write by its reply, the agent's
	// listChanged and the next fetch, so writes built on it undid each other inside that
	// window. Here no list lands until all three are asked: the pick, the editor's commit and
	// the tree menu's initramfs pick, all from one render.
	@Test("P41: a kernel write in flight is never undone by the next one")
	func aWriteInFlightIsNeverUndone() async throws {
		let h = await DesktopHarness.make([Samples.kernelBoot()])
		let stale = h.viewModel.vms[0]
		let lts = try #require(stale.boot.ownedKernels?.first { $0.tag == "6.6-lts" }).path
		let line = "console=hvc0 root=/dev/vda2 quiet"
		let gate = ReplyGate()
		h.stub.pause = { method in
			if method == "listVMs" { await gate.wait() }
		}
		h.viewModel.setActiveKernelFile(stale, role: .kernel, path: lts)
		h.viewModel.setKernelCommandLine("Kernel Lab", line)
		h.viewModel.setActiveKernelFile(stale, role: .initramfs, path: nil)
		#expect(await eventually { !h.stub.kernelSettingsSent.isEmpty })
		gate.open()
		#expect(await eventually { h.stub.kernelSettingsSent.count == 3 })
		let sent = h.stub.kernelSettingsSent.map(\.settings)
		#expect(sent.count == 3)
		guard sent.count == 3 else { return }
		#expect(sent[1].kernelPath == lts, "the commit undid the pick")
		#expect(sent[1].commandLine == line)
		let last = KernelSettings(kernelPath: lts, initrdPath: nil, commandLine: line)
		#expect(sent[2] == last, "the initramfs pick undid the pick or the commit")
		#expect(await eventually { h.viewModel.vms[0].boot.kernel == last })
	}

	// Review F15 (wave r3w3): the command line commits on disappear, after its VM may have
	// left the list (deleted inside the debounce, or renamed with the new list first). A write
	// for a VM the list doesn't hold sent a whole replacement built on empty settings and
	// alerted; it sends nothing.
	@Test("P41: a commit for a VM that left the list sends nothing")
	func aCommitForAVMThatLeftSendsNothing() async throws {
		let h = await DesktopHarness.make([Samples.kernelBoot(), Samples.linux("Alpine")])
		h.stub.vms["Kernel Lab"] = nil
		h.stub.emit(.listChanged)
		#expect(await eventually { !h.viewModel.vms.contains { $0.name == "Kernel Lab" } })
		h.viewModel.setKernelCommandLine("Kernel Lab", "console=hvc0 quiet")
		try await Task.sleep(for: .milliseconds(300))
		#expect(!h.stub.calls.contains("updateKernelSettings"), "\(h.stub.calls)")
		#expect(h.viewModel.presentedError == nil, "\(h.viewModel.presentedError?.title ?? "")")
	}
}
