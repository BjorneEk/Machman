//
//  PickerFloorTests.swift
//  MachmanDesktopUITests
//
//  L7: at the inspector's 250 pt floor a picker cut its value to a stub — the serial
//  Profile read "On…" beside its reload and settings icons, the Resolution "Auto (H…" and
//  "2560 ×…". A popup is as wide as its value when the row lets it, so one drawn narrower
//  at the floor than in the inspector's widest column is cut: that compares every picker of
//  the inspectors that have one, whatever draws it. And each picker's tooltip names its
//  value, for a value too long for any width (a long profile name).
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
struct PickerFloorTests {
	private func inspector(
		_ h: UIHarness, _ vm: String, _ node: SidebarNode?, width: CGFloat
	) async throws -> AXSnapshot {
		h.viewModel.select(name: vm)
		h.viewModel.treeSelection = node.map { [$0] } ?? []
		return try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm(vm)),
			width: width, height: 900)
	}

	private static func pickers(_ tree: AXSnapshot) -> [AXSnapshot] {
		tree.findAll { $0.role == "AXPopUpButton" }
	}

	private static let console = SidebarNode.serial(SerialPortRef(kind: .console, index: 0))

	@Test("L7: no inspector picker is narrower at the 250 pt floor than at its widest")
	func pickersFitTheFloor() async throws {
		let h = await UIHarness.make([
			Samples.linux("Debian", state: .running), Samples.kernelBoot(),
			Samples.linuxDisplay("Wide", width: 2560, height: 1600),
			Samples.linuxDisplay("Odd", width: 1700, height: 1000),
			Samples.linuxDisplay("Host", width: 3024, height: 1964),
		])
		_ = await eventually { h.viewModel.capabilities != nil }
		let floor = MainWindowLayout.inspector.min
		let widest = MainWindowLayout.inspector.max
		#expect(floor == 250)
		var read = 0
		for (vm, node) in [
			("Debian", Self.console), ("Kernel Lab", .serial(SerialPortRef(kind: .uart, index: 0))),
			("Debian", .device(.graphics)), ("Wide", .device(.graphics)),
			("Odd", .device(.graphics)), ("Host", .device(.graphics)),
			("Debian", nil), ("Kernel Lab", nil), ("Debian", .mount(Samples.srcMountID)),
		] as [(String, SidebarNode?)] {
			let narrow = Self.pickers(try await inspector(h, vm, node, width: floor))
			let wide = Self.pickers(try await inspector(h, vm, node, width: widest))
			#expect(narrow.count == wide.count, "\(vm) \(String(describing: node))")
			for (cut, whole) in zip(narrow, wide) {
				read += 1
				let at250 = try #require(cut.frame?.width)
				let atWidest = try #require(whole.frame?.width)
				let what = "\(vm) \(String(describing: node)): “\(whole.value ?? whole.text ?? "")”"
				#expect(at250 >= atWidest - 0.5, "\(what) \(at250) pt, \(atWidest) pt at \(widest)")
			}
		}
		#expect(read >= 15, "only \(read) pickers read")
	}

	@Test("L7: an inspector picker's tooltip names its value, Auto with the host screen's size")
	func pickerTooltipsNameTheirValue() async throws {
		let h = await UIHarness.make([
			Samples.linux("Debian", state: .running),
			Samples.linuxDisplay("Wide", width: 2560, height: 1600),
		])
		_ = await eventually { h.viewModel.capabilities != nil }
		let serial = try await inspector(h, "Debian", Self.console, width: 320)
		let profile = h.profiles.profile(vm: "Debian", ref: SerialPortRef(kind: .console, index: 0))
		#expect(serial.control(labelled: "Profile")?.help == profile.name, "\(serial.dump())")
		#expect(serial.control(labelled: "Mode")?.help == "Reset on Boot")
		#expect(serial.control(labelled: "Max size")?.help == "Unlimited")

		let auto = try await inspector(h, "Debian", .device(.graphics), width: 320)
		let resolution = try #require(auto.control(labelled: "Resolution"), "\(auto.dump())")
		#expect(resolution.value == "Auto")
		#expect(resolution.help == "Auto (host screen, 3024 \u{00D7} 1964)")
		let wide = try await inspector(h, "Wide", .device(.graphics), width: 320)
		#expect(wide.control(labelled: "Resolution")?.help == "2560 \u{00D7} 1600")

		let machine = try await inspector(h, "Debian", nil, width: 320)
		#expect(machine.control(labelled: "Bootloader")?.help == "EFI", "\(machine.dump())")
	}
}
