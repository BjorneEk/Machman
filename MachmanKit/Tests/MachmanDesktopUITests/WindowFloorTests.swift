//
//  WindowFloorTests.swift
//  MachmanDesktopUITests
//
//  The main window's floors and its toolbar, from VMNavigationView hosted offscreen in a
//  titled, never-ordered window at its fitting size: the floor with the inspector open and
//  closed (W3-39, L1) and with three canvas panes (W3-61, L2), the toolbar's safe chip only
//  in a safe run (15), and the inspector toggle's name (W4-27, H32). The numbers are the
//  rows' (±16 pt, T22) and match the window.main.*floor renders (2× PNGs). The » overflow,
//  growing the window and frame restore are live-window behaviour (manual).
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

// L1: desktop views hosted offscreen (chrome .window), read through in-process accessibility.
@MainActor
struct WindowFloorTests {
	static let tolerance: CGFloat = 16
	static let safeHelp = "Safe mode \u{2014} changes are discarded on stop"

	private func window(_ h: UIHarness, _ name: String) -> some View {
		VMNavigationView(
			viewModel: h.viewModel, windowState: .constant(MainWindowState(selection: name)),
			profiles: h.profiles)
	}

	// The window's size (nil: its fitting size, the floor) and its tree, toolbar included.
	private func floor(
		_ h: UIHarness, _ name: String, width: CGFloat? = nil, height: CGFloat? = nil
	) async throws -> (CGSize, AXSnapshot) {
		h.viewModel.select(name: name)
		return try await OffscreenHost.withHost(
			window(h, name), width: width, height: height, chrome: .window
		) { ($0.bounds.size, $0.snapshot()) }
	}

	// Wide enough for every toolbar item: at the floor some go behind the » overflow.
	private func roomy(_ h: UIHarness, _ name: String) async throws -> AXSnapshot {
		try await floor(h, name, width: 1280, height: 720).1
	}

	private func about(_ value: CGFloat, _ target: CGFloat) -> Bool {
		abs(value - target) <= Self.tolerance
	}

	private func toolbar(_ tree: AXSnapshot) -> AXSnapshot? {
		tree.all.first { $0.role == "AXToolbar" }
	}

	@Test("W3-39: the main window floors at about 878 open and 578 closed")
	func theWindowFloors() async throws {
		#expect(MainWindowLayout.canvasMinWidth(panes: 1) == 300)
		#expect(MainWindowLayout.canvasMinWidth(panes: 2) == 300)
		#expect(MainWindowLayout.canvasMinWidth(panes: 3) == 378)
		#expect(MainWindowLayout.sidebar.min == 230)
		#expect(MainWindowLayout.inspector.min == 250)

		let h = await UIHarness.make(select: "Debian")
		h.viewModel.showInfoPanel = true
		let (open, _) = try await floor(h, "Debian")
		#expect(about(open.width, 878) && about(open.height, 352), "open: \(open)")
		h.viewModel.showInfoPanel = false
		let (closed, _) = try await floor(h, "Debian")
		#expect(about(closed.width, 578) && about(closed.height, 352), "closed: \(closed)")
		// Opening the inspector raises the floor by about its own minimum.
		#expect(about(open.width - closed.width, 300), "\(open) vs \(closed)")
	}

	@Test("W3-61: three canvas panes raise the closed floor to about 656")
	func threePanesRaiseTheFloor() async throws {
		let h = await UIHarness.make(select: "Kernel Lab")
		// WindowScenes.threePanes: configuration, Console 0 and UART 0 side by side.
		var canvas = h.canvases.canvas(for: "Kernel Lab")
		let console = SerialPortRef(kind: .console, index: 0)
		let uart = SerialPortRef(kind: .uart, index: 0)
		canvas.open(.config)
		canvas.open(.terminal(console))
		canvas.open(.terminal(uart))
		canvas.split(.terminal(console))
		canvas.split(.terminal(uart))
		h.canvases.setCanvas(canvas, for: "Kernel Lab")
		#expect(h.canvases.canvas(for: "Kernel Lab").panes.count == 3)
		h.viewModel.showInfoPanel = false
		let (closed, _) = try await floor(h, "Kernel Lab")
		#expect(about(closed.width, 656) && about(closed.height, 352), "\(closed)")
	}

	// H44 (C7: window, inset): the corner's toasts and progress cards sit at the window's
	// bottom right, moved left past the inspector while it shows, so they never cover its
	// last rows.
	@Test("H44: toasts and progress cards stay off the inspector column")
	func theCornerStaysOffTheInspector() async throws {
		let h = await UIHarness.make(select: "Debian")
		let message = "Added disk"
		h.viewModel.pushToast(symbol: MachmanSymbols.diskStorage, message: message, sticky: true)
		let copy = Samples.copyOperation()
		h.stub.emit(.operationChanged(op: copy))
		#expect(await eventually { !h.operations.operations.isEmpty })
		h.viewModel.showInfoPanel = true
		let open = try await roomy(h, "Debian")
		let toast = try #require(open.find(text: message)?.frame, "\(open.dump())")
		let card = try #require(open.find(text: copy.displayTitle)?.frame, "\(open.dump())")
		let inspector = try #require(
			open.find(role: "AXHeading", text: "Machine")?.frame, "\(open.dump())")
		#expect(toast.maxX <= inspector.minX, "the toast \(toast) covers the inspector")
		#expect(card.maxX <= inspector.minX, "the card \(card) covers the inspector")
		h.viewModel.showInfoPanel = false
		let closed = try await roomy(h, "Debian")
		let alone = try #require(closed.find(text: message)?.frame)
		#expect(alone.maxX >= 1280 - 40, "the toast \(alone) left the window's corner")
	}

	// H33: an item that goes behind the toolbar's » shows in its menu by its title, so every
	// item needs one, image-only or not, and it reads as a command in Title Case, not as the
	// tooltip's sentence (review F9). The overflow menu itself is AppKit's (manual row).
	@Test("H33: every main and torn toolbar item has a title for the overflow menu")
	func everyToolbarItemHasATitle() async throws {
		let h = await UIHarness.make([
			Samples.linuxSafeRun("Debian"), Samples.linux("Alpine"), Samples.macOS("Sequoia"),
			Samples.kernelBoot(state: .starting), Samples.stoppingLinux("Fedora"),
		], select: "Debian")
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: Samples.downloadingMacInstall()))
		#expect(await eventually { h.viewModel.isInstalling(h.vm("Sequoia")) })
		h.viewModel.showInfoPanel = true
		// Each item's name in the » menu: its label, else its menu form's title (a spinner
		// item has only that), and a group's controls' labels.
		func items(_ view: some View) async throws -> [(label: String, parts: [String])] {
			try await OffscreenHost.withHost(view, width: 1280, height: 720, chrome: .window) {
				// Spaces and the split view's separators are layout, not items to name.
				($0.window.toolbar?.items ?? [])
					.filter { item in
						let id = item.itemIdentifier.rawValue
						return !id.hasPrefix("NSToolbar") && !id.contains("Separator")
					}
					.map { item in
						let name = item.label.isEmpty
							? item.menuFormRepresentation?.title ?? "" : item.label
						let parts = (item as? NSToolbarItemGroup)?.subitems ?? []
						return (name, parts.map(\.label))
					}
			}
		}
		// Running safe, stopped, installing, starting and stopping: each state's controls.
		var bars: [String: [(label: String, parts: [String])]] = [:]
		for vm in ["Debian", "Alpine", "Sequoia", "Kernel Lab", "Fedora"] {
			h.viewModel.select(name: vm)
			bars[vm] = try await items(window(h, vm))
		}
		let torn = try await items(TornTabWindowView(
			connection: h.connection, profiles: h.profiles,
			payload: TornTab(vm: "Debian", tab: .config)))
		#expect(!torn.isEmpty, "\(torn)")
		let all = bars.values.flatMap { $0 } + torn
		let names = all.flatMap { [$0.label] + $0.parts }
		#expect(names.count >= 30, "\(names)")
		#expect(!names.contains(""), "untitled toolbar items in \(names)")
		let sentences = names.filter { !Self.isTitle($0) }
		#expect(sentences.isEmpty, "not Title Case: \(sentences)")

		func group(_ vm: String, _ title: String) -> [String]? {
			bars[vm]?.first { $0.label == title && !$0.parts.isEmpty }?.parts
		}
		#expect(group("Alpine", "Start") == ["Start", "Start Safe"], "\(bars["Alpine"] ?? [])")
		#expect(group("Sequoia", "Start") == ["Start", "Start Safe"], "\(bars["Sequoia"] ?? [])")
		#expect(group("Debian", "Shut Down") == ["Shut Down", "Force Stop"])
		#expect(bars["Alpine"]?.contains { $0.label == "Open Window" } == true)
		#expect(bars["Debian"]?.contains { $0.label == "Close Window" } == true)
	}

	// A toolbar title as wording rule 3 has it: every word capitalized but the small ones, no
	// dash-joined explanation. A VM's own name (the indicator) passes.
	private static func isTitle(_ text: String) -> Bool {
		let small: Set<String> = ["a", "and", "or", "of", "to", "the", "in", "on", "for"]
		guard !text.contains("\u{2014}") else { return false }
		return text.split(separator: " ").enumerated().allSatisfy { index, word in
			guard let first = word.first, first.isLetter else { return true }
			return first.isUppercase || (index > 0 && small.contains(String(word)))
		}
	}

	@Test("15: the toolbar's safe chip shows only while the VM runs safe")
	func theSafeChipShowsOnlyInASafeRun() async throws {
		let h = await UIHarness.make(
			[Samples.linuxSafeRun("Debian"), Samples.linux("Alpine", state: .running)])
		h.viewModel.showInfoPanel = false
		let safe = try await roomy(h, "Debian")
		let safeBar = try #require(toolbar(safe), "\(safe.dump())")
		#expect(safeBar.all.contains { $0.help == Self.safeHelp }, "\(safeBar.dump())")
		let plain = try await roomy(h, "Alpine")
		let plainBar = try #require(toolbar(plain))
		#expect(!plainBar.all.contains { $0.help == Self.safeHelp }, "\(plainBar.dump())")
	}

	@Test("W4-27: a torn window's toolbar reads Show or Hide Inspector")
	func theTornInspectorToggleReadsItsName() async throws {
		let h = await UIHarness.make(select: "Debian")
		for (shown, name) in [(true, "Hide Inspector"), (false, "Show Inspector")] {
			let tree = try await OffscreenHost.withHost(
				TornTabWindowView(
					connection: h.connection, profiles: h.profiles,
					payload: TornTab(vm: "Debian", tab: .config), inspectorShown: shown),
				width: 800, height: 520, chrome: .window
			) { $0.snapshot() }
			let bar = try #require(toolbar(tree), "\(tree.dump())")
			let toggle = try #require(bar.find(label: name), "\(bar.dump())")
			#expect(toggle.role == "AXButton")
		}
	}

	@Test("W4-27: the main toolbar's inspector toggle reads Show or Hide Inspector")
	func theInspectorToggleReadsItsName() async throws {
		let h = await UIHarness.make(select: "Debian")
		h.viewModel.showInfoPanel = true
		let shown = try await roomy(h, "Debian")
		#expect(shown.find(label: "Hide Inspector") != nil, "\(shown.dump())")
		h.viewModel.showInfoPanel = false
		let hidden = try await roomy(h, "Debian")
		#expect(hidden.find(label: "Show Inspector") != nil, "\(hidden.dump())")
		#expect(hidden.find(label: "Hide Inspector") == nil)
	}
}
