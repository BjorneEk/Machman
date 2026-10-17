//
//  OpenPanelFlowTests.swift
//  MachmanDesktopUITests
//
//  The add flows' open panels, answered by the test (OpenPanels, Q21): New VM ▸ macOS ▸ From
//  an IPSW File… creates the VM only once a file is picked and installs from it, and Cancel
//  leaves nothing behind (W3-19, H21); each panel says what it is for, names its button and
//  offers only the files it can take (H63). No panel opens and no view is hosted.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@MainActor
struct OpenPanelFlowTests {
	private static func answering(
		_ url: URL?, asked: @escaping (OpenPanelRequest) -> Void = { _ in }
	) -> OpenPanels {
		OpenPanels { request, answer in
			asked(request)
			answer(url)
		}
	}

	@Test("W3-19: cancelling the IPSW panel creates no VM, a picked file creates and installs one")
	func theIPSWPanelCreatesOnlyOnAPick() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		var asked: [OpenPanelRequest] = []
		AddFlows.newMacFromFile(
			viewModel: h.viewModel, panels: Self.answering(nil) { asked.append($0) })
		try await Task.sleep(for: .milliseconds(200))
		#expect(asked == [.restoreImage], "the restore-image pick")
		#expect(!h.stub.calls.contains("createVM"), "Cancel created a VM: \(h.stub.calls)")

		let ipsw = URL(fileURLWithPath: "/Users/demo/Downloads/UniversalMac_26.0_Restore.ipsw")
		AddFlows.newMacFromFile(viewModel: h.viewModel, panels: Self.answering(ipsw))
		#expect(await eventually { h.stub.calls.contains("startMacInstall") }, "\(h.stub.calls)")
		#expect(h.stub.calls.filter { $0 == "createVM" }.count == 1)
	}

	@Test("H63: each open panel says what it is for, names its button and filters its files")
	func eachPanelSaysWhatItIsFor() async throws {
		let h = await UIHarness.make([Samples.linux("Debian")])
		var asked: [OpenPanelRequest] = []
		let panels = Self.answering(nil) { asked.append($0) }
		AddFlows.chooseExistingDisk(viewModel: h.viewModel, vm: "Debian", panels: panels)
		AddFlows.chooseMountFolder(viewModel: h.viewModel, vm: "Debian", panels: panels)
		for role in [KernelRole.kernel, .initramfs] {
			AddFlows.chooseKernelFile(
				viewModel: h.viewModel, vm: "Debian", role: role, panels: panels)
		}
		AddFlows.newMacFromFile(viewModel: h.viewModel, panels: panels)
		#expect(asked.map(\.message) == [
			"Choose a disk image to add to Debian", "Choose a folder to share with Debian",
			"Choose a kernel image for Debian", "Choose an initramfs for Debian",
			"Choose a macOS restore image to install",
		])
		#expect(asked.map(\.prompt) == ["Add", "Add", "Add", "Add", "Install"])
		#expect(asked.map(\.pick) == [.file, .folder, .file, .file, .file])
		#expect(asked.first?.contentTypes == [.diskImage, .data])
		let untyped = asked.dropFirst().dropLast().map { $0.contentTypes.isEmpty }
		#expect(untyped == [true, true, true], "a folder, a kernel and an initramfs")
		// Typed by its extension: com.apple.itunes.ipsw where a Mac declares it, a dynamic
		// type that still filters by the extension where none does.
		#expect(asked.last?.contentTypes.map(\.preferredFilenameExtension) == ["ipsw"])
	}
}
