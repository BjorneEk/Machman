//
//  TreeMenuContentTests.swift
//  MachmanDesktopUITests
//
//  The device tree's row menus by their content (TreeMenuProbe): consoles and sessions offer
//  Move to New Window until they are torn off (T6), a running VM's stop-first items show
//  dimmed with the reason (W2-18, P14), only an item that asks carries an ellipsis (W2-20,
//  H2), and each row kind lists its items in one order (R3W1-13). Read only: no item is
//  pressed (Copy and Paste reach the pasteboard, Show in Finder reaches Finder).
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
struct TreeMenuContentTests {
	private static let console0 = SerialPortRef(kind: .console, index: 0)
	private static let iso = "iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso"

	// The menu's items as a person reads them, in order.
	private func items(
		_ h: UIHarness, _ vm: String, _ menu: @escaping @MainActor (TreeContext) -> AnyView
	) async throws -> [AXSnapshot] {
		let tree = try await h.snapshot(TreeMenuProbe(harness: h, vm: h.vm(vm), content: menu))
		return tree.findAll { $0.role == "AXButton" }
	}

	private func titles(
		_ h: UIHarness, _ vm: String, _ menu: @escaping @MainActor (TreeContext) -> AnyView
	) async throws -> [String] {
		try await items(h, vm, menu).compactMap(\.text)
	}

	private static func serial(_ vm: VMInfo, _ ref: SerialPortRef, ctx: TreeContext) -> AnyView {
		let port = vm.port(for: ref)!
		return AnyView(ctx.serialMenu(
			port, ref: ref, open: false, gated: port.unavailable != nil,
			enabled: port.enabled ?? true))
	}

	private static func disk(_ vm: VMInfo, _ id: String, ctx: TreeContext) -> AnyView {
		AnyView(ctx.diskMenu(vm.disks.first { $0.id == id }!))
	}

	// MARK: - T6

	@Test("T6: console and session row menus offer Move to New Window")
	func consoleAndSessionOfferANewWindow() async throws {
		let h = await UIHarness.make(select: "Debian")
		let debian = h.vm("Debian")
		let move = "Move to New Window"
		let console = try await titles(h, "Debian") { Self.serial(debian, Self.console0, ctx: $0) }
		#expect(console.contains(move), "\(console)")
		let session = SSHSessionRef(title: "Session 1")
		let docked = try await titles(h, "Debian") {
			AnyView($0.sshSessionMenu(session, torn: false))
		}
		#expect(docked.contains(move), "\(docked)")

		// Torn off already: the window exists, so the item goes.
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .terminal(Self.console0)))
		let tornConsole = try await titles(h, "Debian") {
			Self.serial(debian, Self.console0, ctx: $0)
		}
		#expect(!tornConsole.contains(move), "\(tornConsole)")
		let tornSession = try await titles(h, "Debian") {
			AnyView($0.sshSessionMenu(session, torn: true))
		}
		#expect(!tornSession.contains(move), "\(tornSession)")
	}

	// MARK: - W2-18

	@Test("W2-18: a running VM's disk, ISO, port and kernel menus dim with the reason")
	func runningMenusDimWithTheReason() async throws {
		let h = await UIHarness.make(
			[Samples.linux("Debian", state: .running), Samples.kernelBoot(state: .running)],
			select: "Debian")
		let debian = h.vm("Debian")
		let owned = try await items(h, "Debian") { Self.disk(debian, "storage:system", ctx: $0) }
		expectDimmed(owned, "Rename", "Stop the VM to rename its disks")
		expectDimmed(owned, "Delete\u{2026}", "Stop the VM to remove its disks")

		let iso = try await items(h, "Debian") { Self.disk(debian, Self.iso, ctx: $0) }
		expectDimmed(iso, "Promote to Owned", "Stop the VM to promote its disks")
		expectDimmed(iso, "Remove", "Stop the VM to remove its disks")

		let port = try await items(h, "Debian") { Self.serial(debian, Self.console0, ctx: $0) }
		expectDimmed(port, "Remove", "Stop the VM to add or remove serial ports")

		let lab = h.vm("Kernel Lab")
		let kernel = try #require(lab.kernelTreeEntries(role: .kernel).first { $0.owned })
		let kernelItems = try await items(h, "Kernel Lab") {
			AnyView($0.kernelEntryMenu(kernel, role: .kernel))
		}
		expectDimmed(kernelItems, "Rename", "Stop the VM to rename its kernel files")
		// What changes no file stays live: Copy and Show in Finder.
		for title in ["Copy", "Show in Finder"] {
			#expect(kernelItems.first { $0.text == title }?.isEnabled == true, "\(title)")
		}
	}

	private func expectDimmed(
		_ items: [AXSnapshot], _ title: String, _ reason: String,
		sourceLocation: SourceLocation = #_sourceLocation
	) {
		guard let item = items.first(where: { $0.text == title }) else {
			Issue.record("no item \(title) in \(items.compactMap(\.text))",
				sourceLocation: sourceLocation)
			return
		}
		#expect(!item.isEnabled, "\(title) is enabled", sourceLocation: sourceLocation)
		#expect(item.help == reason, sourceLocation: sourceLocation)
	}

	// MARK: - W2-20

	@Test("W2-20: Remove and Promote to Owned carry no ellipsis, Delete… does")
	func onlyAQuestionCarriesAnEllipsis() async throws {
		var external = Samples.kernelBoot()
		external.boot.kernel?.kernelPath = "/Users/demo/Downloads/vmlinuz-6.13"
		let h = await UIHarness.make([Samples.linux("Alpine"), external], select: "Alpine")
		let alpine = h.vm("Alpine")
		let mount = try await titles(h, "Alpine") { AnyView($0.mountMenu(alpine.mounts[0])) }
		let iso = try await titles(h, "Alpine") { Self.disk(alpine, Self.iso, ctx: $0) }
		let port = try await titles(h, "Alpine") { Self.serial(alpine, Self.console0, ctx: $0) }
		let file = try #require(
			h.vm("Kernel Lab").kernelTreeEntries(role: .kernel).first { !$0.owned })
		let kernel = try await titles(h, "Kernel Lab") {
			AnyView($0.kernelEntryMenu(file, role: .kernel))
		}
		#expect(mount.contains("Remove"), "\(mount)")
		#expect(iso.contains("Remove") && iso.contains("Promote to Owned"), "\(iso)")
		#expect(port.contains("Remove"), "\(port)")
		#expect(kernel.contains("Promote to Owned"), "\(kernel)")
		for title in mount + iso + port + kernel {
			#expect(!title.hasSuffix("\u{2026}") && !title.hasSuffix("..."), "\(title)")
		}

		let owned = try await titles(h, "Alpine") { Self.disk(alpine, "storage:system", ctx: $0) }
		#expect(owned.contains("Delete\u{2026}"), "\(owned)")
	}

	// MARK: - R3W1-13

	@Test("R3W1-13: every tree row kind's menu lists its items in order")
	func everyMenuKeepsItsOrder() async throws {
		let h = await UIHarness.make(
			[Samples.linux("Alpine"), Samples.kernelBoot()], select: "Alpine")
		let alpine = h.vm("Alpine")
		let lab = h.vm("Kernel Lab")
		let session = SSHSessionRef(title: "Session 1")
		let network = try #require(alpine.devices?.first { $0.kind == .network })
		let kernel = try #require(lab.kernelTreeEntries(role: .kernel).first { $0.active })
		let golden: [(String, String, @MainActor (TreeContext) -> AnyView, [String])] = [
			("root", "Alpine", { AnyView($0.rootMenu()) },
				["Rename", "Paste", "Delete VM\u{2026}"]),
			("owned disk", "Alpine", { Self.disk(alpine, "storage:system", ctx: $0) },
				["Copy", "Show in Finder", "Disable", "Rename", "Delete\u{2026}"]),
			("ISO", "Alpine", { Self.disk(alpine, Self.iso, ctx: $0) },
				["Copy", "Show in Finder", "Disable", "Promote to Owned", "Remove"]),
			("mount", "Alpine", { AnyView($0.mountMenu(alpine.mounts[0])) },
				["Copy", "Show in Finder", "Disable", "Remove"]),
			("console", "Alpine", { Self.serial(alpine, Self.console0, ctx: $0) },
				["Open Terminal (connect)", "Move to New Window", "Properties", "Disable",
					"Remove"]),
			("session", "Alpine", { AnyView($0.sshSessionMenu(session, torn: false)) },
				["Move to New Window", "Close Session"]),
			("device", "Alpine", { AnyView($0.deviceMenu(network)) }, ["Disable", "Remove"]),
			("owned kernel", "Kernel Lab", { AnyView($0.kernelEntryMenu(kernel, role: .kernel)) },
				["Deselect", "Copy", "Show in Finder", "Rename", "Delete\u{2026}"]),
		]
		for (kind, vm, menu, expected) in golden {
			let read = try await titles(h, vm, menu)
			#expect(read == expected, "\(kind)")
		}
	}
}
