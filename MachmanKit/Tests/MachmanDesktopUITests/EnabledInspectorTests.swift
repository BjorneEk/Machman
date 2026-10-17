//
//  EnabledInspectorTests.swift
//  MachmanDesktopUITests
//
//  H58: the serial and device inspectors carry the Enabled toggle the disk and mount
//  inspectors have, and a port's inspector offers Remove where the tree's menu does — on a
//  kind's last port, stop-first. Read from the real inspectors hosted offscreen; what a
//  toggle sends is the view model's setEnabled (BatchEnableTests). The tree's device
//  Disable sends the same setEnabled, never the device's whole settings (review F18).
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
struct EnabledInspectorTests {
	private func inspector(
		_ h: UIHarness, _ vm: String, _ node: SidebarNode
	) async throws -> AXSnapshot {
		h.viewModel.select(name: vm)
		h.viewModel.treeSelection = [node]
		return try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm(vm)),
			width: 320, height: 820)
	}

	private func trash(_ tree: AXSnapshot) -> AXSnapshot? {
		tree.all.first { $0.role == "AXButton" && $0.identifier == MachmanSymbols.delete }
	}

	private static let portsHelp = "Disabled ports are not attached at the next start"
	private static let devicesHelp = "Disabled devices are left out at the next start"

	@Test("H58: serial and device inspectors list an Enabled toggle, and only the last port Remove")
	func portsAndDevicesOfferEnabled() async throws {
		let h = await UIHarness.make([
			Samples.linux("Debian", state: .running), Samples.linuxConsolesReported("Alpine"),
			Samples.disabledConsole("Kali", state: .stopped), Samples.kernelBoot(),
			Samples.linuxNoDisplay("Fedora", state: .stopped),
		])
		func console(_ index: Int) -> SidebarNode {
			.serial(SerialPortRef(kind: .console, index: index))
		}

		// A running VM's only console: on, and its Remove dimmed with the reason.
		let running = try await inspector(h, "Debian", console(0))
		let toggle = try #require(running.control(labelled: "Enabled"), "\(running.dump())")
		#expect(toggle.role == "AXCheckBox")
		#expect(toggle.value == "1")
		#expect(toggle.help == Self.portsHelp)
		let dimmed = try #require(trash(running), "\(running.dump())")
		#expect(dimmed.label == "Remove console port")
		#expect(dimmed.help == StoppedOnly.changeSerialPorts.stopFirst)
		#expect(!dimmed.isEnabled)

		// Four consoles: only the last one offers Remove.
		let first = try await inspector(h, "Alpine", console(0))
		#expect(first.control(labelled: "Enabled") != nil, "\(first.dump())")
		#expect(trash(first) == nil, "\(first.dump())")
		let last = try await inspector(h, "Alpine", console(3))
		let remove = try #require(trash(last), "\(last.dump())")
		#expect(remove.label == "Remove console port")
		#expect(remove.isEnabled)

		// A disabled console reads off; a stopped VM's UART offers its own Remove.
		let off = try await inspector(h, "Kali", console(0))
		#expect(off.control(labelled: "Enabled")?.value == "0", "\(off.dump())")
		let uart = try await inspector(
			h, "Kernel Lab", .serial(SerialPortRef(kind: .uart, index: 0)))
		#expect(trash(uart)?.label == "Remove UART port", "\(uart.dump())")
		#expect(trash(uart)?.isEnabled == true)

		// Every device inspector: the generic one and one with settings, on and off.
		let keyboard = try await inspector(h, "Debian", .device(.keyboard))
		let on = try #require(keyboard.control(labelled: "Enabled"), "\(keyboard.dump())")
		#expect(on.value == "1")
		#expect(on.help == Self.devicesHelp)
		#expect(trash(keyboard)?.label == "Remove Keyboard")
		let display = try await inspector(h, "Fedora", .device(.graphics))
		#expect(display.control(labelled: "Enabled")?.value == "0", "\(display.dump())")
	}

	// vm.device.update re-sent every setting the row last drew, so a Disable that crossed a
	// settings change on its way could put the old ones back.
	@Test("H58: the tree's device Disable sends setEnabled, not the device's settings")
	func theTreeDisablesADeviceByItsFlag() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		let network = try #require(h.vm("Alpine").devices?.first { $0.kind == .network })
		let pressed = try await OffscreenHost.withHost(
			TreeMenuProbe(harness: h, vm: h.vm("Alpine")) { AnyView($0.deviceMenu(network)) }
		) { hosted in
			AXPress.press(label: "Disable", under: hosted.host)
		}
		#expect(pressed)
		#expect(await eventually { h.stub.calls.contains("setEnabled") }, "\(h.stub.calls)")
		#expect(!h.stub.calls.contains("updateDevice"), "\(h.stub.calls)")
		#expect(h.stub.enabledChanges.last?.devices == ["network": false])
	}
}
