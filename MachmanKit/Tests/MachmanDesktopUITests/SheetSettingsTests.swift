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

	// Review F11: the copy's run renews its identity only when it finds its source's state
	// (a copy of a VM that never ran Guest Setup isn't recognized), and it does so on the
	// BSDs too, so the sheet says when it works, for every guest but macOS.
	@Test("S55: a Duplicate sheet says a set-up VM's copy gets its own address from Guest Setup")
	func duplicateSheetNamesGuestSetupForASetUpCopy() async throws {
		let h = await UIHarness.make([Samples.linux("Debian"), Samples.macOS("Sequoia")])
		let linux = try await h.snapshot(
			CopyVMSheet(vm: h.vm("Debian"), viewModel: h.viewModel))
		let said = "Copies the disk file into the new VM — if this VM has run Guest Setup, run "
			+ "it again in the copy so the copy leases its own address"
		#expect(linux.all.contains { $0.help == said }, "\(linux.dump())")
		let mac = try await h.snapshot(CopyVMSheet(vm: h.vm("Sequoia"), viewModel: h.viewModel))
		#expect(mac.all.contains { $0.help == "Copies the disk file into the new VM" },
			"\(mac.dump())")
		#expect(!mac.all.contains { $0.help?.contains("Guest Setup") == true }, "\(mac.dump())")
	}

	@Test("P44: the New Disk page and the Grow field refresh the free space as they appear")
	func sizeFormsRefreshTheFreeSpace() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")], select: "Alpine")
		let asked = { h.stub.calls.filter { $0 == "hostCapabilities" }.count }
		_ = await eventually { h.viewModel.capabilities != nil }   // the connection's own ask
		let before = asked()
		_ = try await h.snapshot(
			AddPopover(viewModel: h.viewModel, vm: h.vm("Alpine"), newDisk: true))
		#expect(await eventually { asked() > before }, "\(h.stub.calls)")

		let opened = asked()
		h.viewModel.treeSelection = [.disk("storage:system")]
		_ = try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm("Alpine")),
			width: 320, height: 820)
		#expect(await eventually { asked() > opened }, "\(h.stub.calls)")
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

	@Test("H45: the macOS sheet has no default button and a retry reads Install macOS?")
	func theMacOSSheetHasNoDefault() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine"), Samples.macOSFailedInstall()])
		let first = try await h.snapshot(MacSwitchSheet(viewModel: h.viewModel, vm: h.vm("Alpine")))
		#expect(first.find(text: "Switch to macOS?") != nil, "\(first.dump())")
		let retry = try await h.snapshot(
			MacSwitchSheet(viewModel: h.viewModel, vm: h.vm("Sequoia")))
		#expect(retry.find(text: "Install macOS?") != nil, "\(retry.dump())")
		#expect(!retry.all.contains { $0.text?.contains("switch back") == true },
			"a retry is no switch: \(retry.dump())")
		#expect(retry.find(role: "AXButton", text: "Download Latest")?.isEnabled == true)
		// Irreversible and multi-GB, so Return presses nothing (C21). SwiftUI's buttons are
		// no NSButtons here and expose no key equivalent, so the sheet's source says it.
		let source = try RepoFiles.text("MachmanKit/Sources/MachmanDesktopUI/Inspector/"
			+ "InspectorView.swift")
		let sheet = try #require(source.range(of: "struct MacSwitchSheet")
			.map { String(source[$0.lowerBound...]) })
		let body = sheet.components(separatedBy: "\n}\n").first ?? sheet
		#expect(!body.contains(".defaultAction"), "a default button in MacSwitchSheet")
		#expect(!body.contains(".borderedProminent"), "a button styled as the default")
	}

	@Test("H48: Reset stands alone, tab sliders start derived, profile controls have names")
	func appearanceResetAndLabels() async throws {
		let h = await UIHarness.make()
		// Density 0.8 with the tab sizes on Auto: tabs are 20 pt with 12 pt type.
		let derived = MachmanMetrics(scale: 0.8, fontScale: 1.0)
		#expect(derived.tabHeight == 20 && derived.tabFontSize == 12)
		let look = try await h.snapshot(AppearanceSettingsView(density: 0.8), width: 760)
		let height = try #require(look.control(labelled: "Tab height"), "\(look.dump())")
		#expect(height.value.flatMap(Double.init) == 20, "\(height)")
		let font = try #require(look.control(labelled: "Tab font size"))
		#expect(font.value.flatMap(Double.init) == 12, "\(font)")
		// Reset covers the whole tab, so it sits under the last section, not inside Density.
		let reset = try #require(
			look.find(role: "AXButton", text: "Reset Appearance to Defaults"), "\(look.dump())")
		let follow = try #require(look.find(role: "AXButton", text: "Follow Density & Font Size"))
		#expect((reset.frame?.minY ?? 0) > (follow.frame?.maxY ?? .infinity))

		let terminal = try await h.snapshot(TerminalSettingsView(store: h.profiles))
		#expect(terminal.find(label: "Profile")?.role == "AXPopUpButton", "\(terminal.dump())")
		for index in 0..<16 {
			#expect(terminal.find(label: "ANSI color \(index)") != nil, "ANSI color \(index)")
		}
	}

	// A row's ⋯ menu laid out as views (its content reaches no tree until it opens).
	private func quickActions(_ h: UIHarness, _ vm: String) async throws -> AXSnapshot {
		try await h.snapshot(VStack {
			VMPickerQuickActions(viewModel: h.viewModel, vm: h.vm(vm), dismiss: {})
		})
	}

	@Test("W2-18: a running VM's picker ⋯ menu shows Delete… dimmed with the reason")
	func aRunningVMsPickerMenuDimsDelete() async throws {
		let h = await UIHarness.make(select: "Debian")
		let menu = try await quickActions(h, "Debian")
		let delete = try #require(menu.find(role: "AXButton", text: "Delete\u{2026}"),
			"\(menu.dump())")
		#expect(!delete.isEnabled)
		#expect(delete.help == "Stop the VM to delete it")
		#expect(menu.find(role: "AXButton", text: "Shut Down")?.isEnabled == true)
		#expect(menu.find(role: "AXButton", text: "Start") == nil)
		let stopped = try await quickActions(h, "Alpine")
		#expect(stopped.find(role: "AXButton", text: "Delete\u{2026}")?.isEnabled == true)
		#expect(stopped.find(role: "AXButton", text: "Start")?.isEnabled == true)
	}

	@Test("R3W2-8: an unreached VM's picker ⋯ menu offers Shut Down and Force Stop but no Start")
	func anUnreachedVMsPickerMenuWaits() async throws {
		let h = await UIHarness.make([Samples.unreached()])
		let menu = try await quickActions(h, "Debian")
		#expect(menu.find(role: "AXButton", text: "Shut Down")?.isEnabled == true,
			"\(menu.dump())")
		#expect(menu.find(role: "AXButton", text: "Force Stop")?.isEnabled == true)
		#expect(menu.find(role: "AXButton", text: "Start") == nil)
		#expect(menu.find(role: "AXButton", text: "Start Safe") == nil)
		let delete = try #require(menu.find(role: "AXButton", text: "Delete\u{2026}"))
		#expect(!delete.isEnabled)
		#expect(delete.help == VMInfo.unreachedHelp)
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
