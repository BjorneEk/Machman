//
//  SheetSettingsTests.swift
//  MachmanDesktopUITests
//
//  Sheets, popovers and the Settings window, hosted offscreen as their own views (a sheet
//  or popover never presents here): a spaces-only name dims Duplicate and Save with its
//  reason (W1-4), the Duplicate sheet keeps long disk names inside 400 pt (W3-31, L3), the
//  picker's row menu and the Back chevrons read their tooltips (W3-35, H6), Settings is
//  760 × 600 and scrolls (W3-62, H20), its tabs' titles and symbols (W4-9, W4-11), the
//  profile buttons' names (W4-10, H32) and the default profile's dimmed trash (W3-54, H9).
//

import AppKit
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
struct SheetSettingsTests {
	@Test("W1-4: a spaces-only name shows its reason and dims Duplicate and Save")
	func aBlankNameDimsTheSheets() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine"), Samples.linuxSafeRun("Debian")])
		let reason = try #require(h.viewModel.newVMNameProblem("   "))
		let copy = try await h.snapshot(
			CopyVMSheet(vm: h.vm("Alpine"), viewModel: h.viewModel, name: "   "))
		#expect(copy.find(text: reason) != nil, "\(copy.dump())")
		#expect(copy.find(role: "AXButton", text: "Duplicate")?.isEnabled == false)
		#expect(copy.find(role: "AXButton", text: "Cancel")?.isEnabled == true)

		let save = try await h.snapshot(
			SafeSaveSheet(vm: h.vm("Debian"), viewModel: h.viewModel, name: "   "))
		#expect(save.find(text: reason) != nil, "\(save.dump())")
		#expect(save.find(role: "AXButton", text: "Save")?.isEnabled == false)
		#expect(save.find(role: "AXButton", text: "Cancel")?.isEnabled == true)
	}

	@Test("W3-31: the Duplicate sheet stays 400 pt with long disk names inside it")
	func theDuplicateSheetKeepsItsWidth() async throws {
		let h = await UIHarness.make([Samples.linuxLongDiskNames()])
		try await OffscreenHost.withHost(
			CopyVMSheet(vm: h.vm("Debian"), viewModel: h.viewModel)
		) { hosted in
			#expect(abs(hosted.bounds.width - 400) < 1, "\(hosted.bounds)")
			let tree = hosted.snapshot()
			let outside = tree.all.filter { ($0.frame?.maxX ?? 0) > 401 }
			#expect(outside.isEmpty, "\(outside.map { "\($0.role) \($0.text ?? "")" })")
			#expect(tree.all.contains { $0.text?.contains("scratch-space") == true },
				"the long disk isn't listed: \(tree.dump())")
		}
	}

	@Test("W3-35: the picker's row menu and both Back chevrons read their tooltips")
	func pickerControlsReadTheirTooltips() async throws {
		let h = await UIHarness.make()
		let picker = try await h.snapshot(VMPickerPopover(viewModel: h.viewModel))
		let actions = try #require(picker.find(label: "Actions for Debian"), "\(picker.dump())")
		#expect(actions.help == "Actions for Debian")

		let templates = try await h.snapshot(
			VMPickerPopover(viewModel: h.viewModel, templates: true))
		let add = try await h.snapshot(
			AddPopover(viewModel: h.viewModel, vm: h.vm("Alpine"), newDisk: true))
		for (name, tree) in [("templates", templates), ("new disk", add)] {
			let back = try #require(tree.find(label: "Back"), "\(name): \(tree.dump())")
			#expect(back.help == "Back", "\(name)")
			#expect(back.role == "AXButton", "\(name)")
		}
	}

	@Test("W3-62: Settings is 760 × 600 with Follow Density & Font Size inside it")
	func settingsFitsAndScrolls() async throws {
		let h = await UIHarness.make()
		try await OffscreenHost.withHost(SettingsRootView(profiles: h.profiles)) { hosted in
			#expect(abs(hosted.bounds.width - 760) < 1 && abs(hosted.bounds.height - 600) < 1,
				"\(hosted.bounds)")
			let tree = hosted.snapshot()
			let follow = try #require(
				tree.find(role: "AXButton", text: "Follow Density & Font Size")?.frame,
				"\(tree.dump())")
			#expect(follow.maxY <= 600, "\(follow)")
			let scroll = try #require(tree.all.first { $0.role == "AXScrollArea" })
			#expect(scroll.find(text: "Follow Density & Font Size") != nil,
				"the pane doesn't scroll as one Form")
		}
	}

	@Test("W4-9: the Settings tabs read Appearance, Terminal and Behavior")
	func settingsTabsReadTheirTitles() async throws {
		let h = await UIHarness.make()
		try await OffscreenHost.withHost(SettingsRootView(profiles: h.profiles)) { hosted in
			// The tab buttons answer AX with their state only; the titles they draw are the
			// tab view's items (read, never selected).
			let tabs = try #require(Self.tabView(in: hosted.host), "no tab view")
			#expect(tabs.tabViewItems.map(\.label) == ["Appearance", "Terminal", "Behavior"])
			let buttons = hosted.snapshot().findAll { $0.subrole == "AXTabButton" }
			#expect(buttons.map(\.value) == ["1", "0", "0"], "Appearance opens first")
		}
	}

	private static func tabView(in view: NSView) -> NSTabView? {
		if let tabs = view as? NSTabView { return tabs }
		for subview in view.subviews {
			if let tabs = tabView(in: subview) { return tabs }
		}
		return nil
	}

	@Test("W4-11: the Settings tabs use the palette, terminal and gear symbols")
	func settingsTabsUseTheirSymbols() throws {
		#expect(MachmanSymbols.settingsAppearance == "paintpalette")
		#expect(MachmanSymbols.settingsTerminal == "terminal")
		#expect(MachmanSymbols.settingsBehavior == "gearshape")
		let source = try RepoFiles.text(
			"MachmanKit/Sources/MachmanDesktopUI/Terminal/SettingsRootView.swift")
		for (title, symbol) in [
			("Appearance", "settingsAppearance"), ("Terminal", "settingsTerminal"),
			("Behavior", "settingsBehavior"),
		] {
			#expect(source.contains(
				"Label(\"\(title)\", systemImage: MachmanSymbols.\(symbol))"), "\(title)")
		}
	}

	@Test("W4-10: Settings ▸ Terminal's profile buttons read their names")
	func profileButtonsReadTheirNames() async throws {
		let h = await UIHarness.make()
		let tree = try await h.snapshot(TerminalSettingsView(store: h.profiles))
		for name in ["New profile", "Duplicate profile", "Delete profile\u{2026}"] {
			let button = try #require(tree.find(label: name), "\(name): \(tree.dump())")
			#expect(button.role == "AXButton")
			#expect(button.help == name)
		}
	}

	@Test("W3-54: the trash button dims on the OneDark default profile")
	func theDefaultProfileCantBeDeleted() async throws {
		let h = await UIHarness.make()
		let defaultProfile = h.profiles.defaultProfile
		#expect(defaultProfile.name == "OneDark")
		h.profiles.editingProfileID = defaultProfile.id
		let tree = try await h.snapshot(TerminalSettingsView(store: h.profiles))
		let trash = try #require(tree.find(label: "Delete profile\u{2026}"), "\(tree.dump())")
		#expect(!trash.isEnabled)
		#expect(tree.find(label: "Duplicate profile")?.isEnabled == true)
	}
}
