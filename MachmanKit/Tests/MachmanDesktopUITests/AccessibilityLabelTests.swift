//
//  AccessibilityLabelTests.swift
//  MachmanDesktopUITests
//
//  What VoiceOver reads on the desktop's image-only controls and stop-first actions, read
//  from the real views hosted offscreen (AXSnapshot): the inspector's discovery button
//  (H23), the toolbar's stop and window controls (H32), a canvas tab (H39), and the device
//  tree's root menu while the VM runs (P14).
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen, read through in-process accessibility.
@MainActor
struct AccessibilityLabelTests {
	@Test("H23: the network inspector's discovery button reads its tooltip")
	func discoveryButtonReadsItsTooltip() async throws {
		let h = await UIHarness.make(select: "Debian")
		h.viewModel.treeSelection = [.device(.network)]
		let tree = try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm("Debian")),
			width: 320, height: 700)
		let button = try #require(tree.find(role: "AXButton", text: "Re-run address discovery"))
		#expect(button.label == "Re-run address discovery")
		#expect(button.help == "Re-run address discovery")
		#expect(button.isEnabled)
	}

	@Test("H32: the toolbar's stop buttons read Shut Down and Force Stop")
	func toolbarStopButtonsReadTheirNames() async throws {
		let h = await UIHarness.make(select: "Debian")
		let debian = h.vm("Debian")
		let tree = try await h.snapshot(HStack {
			WindowToggleItem(viewModel: h.viewModel, vm: debian)
			StartStopGroup(viewModel: h.viewModel, vm: debian)
		})
		for name in ["Shut Down", "Force Stop"] {
			let button = try #require(tree.find(label: name), "no element reads \(name)")
			#expect(button.role == "AXButton")
			#expect(button.help == name)
			#expect(button.isEnabled)
		}
		let toggle = try #require(tree.findAll { $0.subrole == "AXToggle" }.first)
		#expect(toggle.label == VMListViewModel.windowToggleHelp(debian))
		#expect(toggle.label == "Close Window — the VM keeps running")
	}

	@Test("H39: a selected canvas tab reads as a selected button with Close Tab")
	func canvasTabReadsAsASelectedButton() async throws {
		let tree = try await OffscreenHost.withHost(HStack {
			Self.tab("Debian", selected: true)
			Self.tab("Console 0", selected: false)
		}) { $0.snapshot() }
		let selected = try #require(tree.find(label: "Debian"))
		#expect(selected.role == "AXButton")
		#expect(selected.isSelected)
		#expect(selected.actions == ["Close Tab"])
		let other = try #require(tree.find(label: "Console 0"))
		#expect(other.role == "AXButton")
		#expect(!other.isSelected)
		#expect(other.actions == ["Close Tab"])
		// One element per tab: the hover close glyph inside is the pointer's, not VoiceOver's.
		#expect(tree.findAll { $0.role == "AXButton" }.count == 2)
	}

	@Test("P14: a running VM's root menu shows Rename and Delete dimmed with the reason")
	func runningRootMenuDimsStopFirstItems() async throws {
		let h = await UIHarness.make(select: "Debian")
		let running = try await h.snapshot(
			TreeMenuProbe(harness: h, vm: h.vm("Debian")) { AnyView($0.rootMenu()) })
		let rename = try #require(running.find(role: "AXButton", text: "Rename"))
		#expect(!rename.isEnabled)
		#expect(rename.help == "Stop the VM to rename it")
		let delete = try #require(running.find(role: "AXButton", text: "Delete VM\u{2026}"))
		#expect(!delete.isEnabled)
		#expect(delete.help == "Stop the VM to delete it")

		let stopped = try await h.snapshot(
			TreeMenuProbe(harness: h, vm: h.vm("Alpine")) { AnyView($0.rootMenu()) })
		let renameStopped = try #require(stopped.find(role: "AXButton", text: "Rename"))
		#expect(renameStopped.isEnabled)
		#expect(renameStopped.help == nil)
		let deleteStopped = try #require(stopped.find(role: "AXButton", text: "Delete VM\u{2026}"))
		#expect(deleteStopped.isEnabled)
		#expect(deleteStopped.help == nil)
	}

	// H51: a tree row's icon is decoration (the row's text names the entry), and a badge says
	// what its tooltip says. A symbol-name check alone would miss "Move" (folder.fill) and
	// "Syncing" (the automount badge), so every image left must read exactly its help.
	@Test("H51: the device tree's icons read nothing or their help")
	func treeIconsReadNothingOrTheirHelp() async throws {
		let h = await UIHarness.make(
			[Samples.linuxWithMounts("Debian"), Samples.kernelBoot()], select: "Debian")
		// An open session and a torn-off one, so the session rows and their badges show.
		let open = SSHSessionRef(title: "Session 1")
		let torn = SSHSessionRef(title: "Session 2")
		var canvas = h.canvases.canvas(for: "Debian")
		canvas.open(.ssh(open))
		h.canvases.setCanvas(canvas, for: "Debian")
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(torn)))
		var images: [AXSnapshot] = []
		for (vm, section) in [
			("Debian", { AnyView(TreeStorageSection(ctx: $0)) }),
			("Debian", { AnyView(TreeSerialSection(ctx: $0)) }),
			("Debian", { AnyView(TreeSSHSection(ctx: $0)) }),
			("Debian", { AnyView(TreeDevicesSection(ctx: $0)) }),
			("Kernel Lab", { AnyView(TreeKernelSection(ctx: $0)) }),
		] as [(String, @MainActor (TreeContext) -> AnyView)] {
			let tree = try await h.snapshot(
				TreeSectionProbe(harness: h, vm: h.vm(vm), content: section))
			images += tree.findAll { $0.role == "AXImage" }
		}
		let mute = images.filter { $0.help == nil || $0.label != $0.help }
		#expect(mute.isEmpty, "\(mute.map { "\($0.label ?? "nil") / \($0.help ?? "nil")" })")
		#expect(images.contains { $0.label == "Mounts at boot at /mnt/machman/src" },
			"\(images.map { $0.label ?? "nil" })")
		// The root row's boot badge: its text names the mode, so its glyph says nothing.
		let badge = try await h.snapshot(BootBadge(mode: .efi))
		#expect(badge.findAll { $0.role == "AXImage" }.isEmpty, "\(badge.dump())")
		#expect(badge.find(text: "EFI") != nil)
	}

	private static func tab(_ title: String, selected: Bool) -> some View {
		CanvasTabItem(
			title: title, symbol: MachmanSymbols.tabConfig, isTerminal: !selected,
			selected: selected, dragging: false, detachedDrag: false, dragOffset: .zero,
			canSplit: true, hasSiblings: true, closeAsks: false, tabStyle: .capsule,
			metrics: MachmanMetrics(), onSelect: {}, onClose: {}, onCloseOthers: {}, onSplit: {},
			onTearOff: {}, onDragChanged: { _ in }, onDragEnded: {}, reportFrame: { _ in })
	}
}
