//
//  AXCapabilityTests.swift
//  MachmanDesktopUITests
//
//  The canary for AXSnapshot: plain SwiftUI controls, no Machman view, so a macOS or
//  SwiftUI change that stops in-process accessibility from reading shows up here, named by
//  the attribute that stopped — apart from any product change.
//

import AppKit
import SwiftUI
import Testing
import MachmanTestSupport

// L1: in-process accessibility of hosted views (offscreen, never ordered).
@MainActor
struct AXCapabilityTests {
	private var controls: some View {
		VStack {
			Button("Plain") {}.help("Plain help")
			Button("Dimmed") {}.help("Dimmed help").disabled(true)
			Toggle("Switch", isOn: .constant(true))
			Text("Static text")
			Text("Chosen").accessibilityAddTraits(.isSelected)
			Text("Acted").accessibilityAction(named: "Do It") {}
		}
		.padding()
	}

	@Test("Q18: in-process accessibility reads a button's label, help and disabled state")
	func readsButtons() async throws {
		let tree = try await OffscreenHost.withHost(controls) { $0.snapshot() }
		let plain = try #require(tree.find(label: "Plain"), "a Button's label stopped reading")
		#expect(plain.role == "AXButton", "a Button's role stopped reading")
		#expect(plain.help == "Plain help", "a Button's help (.help) stopped reading")
		#expect(plain.isEnabled, "an enabled Button reads as disabled")
		let dimmed = try #require(tree.find(label: "Dimmed"), "a Button's label stopped reading")
		#expect(!dimmed.isEnabled, "a .disabled Button's enabled state stopped reading")
		#expect(dimmed.help == "Dimmed help", "a disabled Button's help stopped reading")
	}

	@Test(
		"Q18: in-process accessibility reads a toggle's value, a selected trait and named actions")
	func readsValuesTraitsAndActions() async throws {
		let tree = try await OffscreenHost.withHost(controls) { $0.snapshot() }
		let toggle = try #require(tree.find(label: "Switch"), "a Toggle's label stopped reading")
		#expect(toggle.role == "AXCheckBox", "a Toggle's role stopped reading")
		#expect(toggle.value == "1", "a Toggle's value stopped reading")
		let text = try #require(tree.find(text: "Static text"), "a Text's value stopped reading")
		#expect(text.role == "AXStaticText")
		let chosen = try #require(tree.find(text: "Chosen"))
		#expect(chosen.isSelected, "the .isSelected trait stopped reading")
		#expect(!text.isSelected)
		let acted = try #require(tree.find(text: "Acted"))
		#expect(acted.actions == ["Do It"], "named accessibility actions stopped reading")
	}

	@Test("Q18: accessibility frames land inside the host's bounds")
	func framesLandInsideTheHost() async throws {
		let (tree, bounds) = try await OffscreenHost.withHost(controls) {
			($0.snapshot(), $0.bounds)
		}
		let buttons = tree.findAll { $0.role == "AXButton" }
		#expect(buttons.count == 2)
		for node in tree.all.dropFirst() {
			let frame = try #require(node.frame, "\(node.role) \(node.text ?? ""): no frame read")
			#expect(frame.width > 0 && frame.height > 0, "\(node.text ?? node.role): \(frame)")
			#expect(bounds.contains(frame), "\(node.text ?? node.role): \(frame) not in \(bounds)")
		}
		// Top-left origin: the first control sits above the last one.
		let plain = try #require(tree.find(label: "Plain")?.frame)
		let acted = try #require(tree.find(text: "Acted")?.frame)
		#expect(plain.minY < acted.minY)
	}

	@Test("Q18: a snapshot's dump is identical across two captures")
	func dumpIsStable() async throws {
		let first = try await OffscreenHost.withHost(controls) { $0.snapshot().dump() }
		let second = try await OffscreenHost.withHost(controls) { $0.snapshot().dump() }
		#expect(first == second)
		#expect(first == """
			AXGroup/AXHostingView
			  AXButton "Plain" help="Plain help"
			  AXButton "Dimmed" help="Dimmed help" [disabled]
			  AXCheckBox "Switch" value="1"
			  AXStaticText "Static text"
			  AXStaticText "Chosen" [selected]
			  AXStaticText "Acted" actions=[Do It]
			""")
	}
}
