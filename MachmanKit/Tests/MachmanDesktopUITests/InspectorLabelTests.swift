//
//  InspectorLabelTests.swift
//  MachmanDesktopUITests
//
//  What VoiceOver reads on the inspectors' and the tree's image-only controls, and what
//  their tooltips say, from the real views hosted offscreen: the MAC regenerate, SSH retry
//  and state dot (W3-34, H23), the memory field's exact bytes (W3-20, H4), a log cap the
//  presets don't list (W3-27, H26), the trash buttons (W4-7, row 18, H11), the port's
//  settings button and the no-display warning (W4-10, H32), and a tree row's Open action
//  (R3W2-37, H39). VoiceOver itself is the assisted tier's.
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
struct InspectorLabelTests {
	private func inspector(
		_ h: UIHarness, _ vm: String, _ node: SidebarNode?
	) async throws -> AXSnapshot {
		h.viewModel.select(name: vm)
		h.viewModel.treeSelection = node.map { [$0] } ?? []
		return try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm(vm)),
			width: 320, height: 820)
	}

	private func button(
		_ tree: AXSnapshot, help: String, sourceLocation: SourceLocation = #_sourceLocation
	) throws -> AXSnapshot {
		try #require(
			tree.all.first { $0.role == "AXButton" && $0.help == help },
			"no button with help \(help): \(tree.dump())", sourceLocation: sourceLocation)
	}

	@Test("W3-34: MAC regenerate, SSH retry and the state dot read their tooltips")
	func imageButtonsReadTheirTooltips() async throws {
		let h = await UIHarness.make(
			[Samples.linux("Alpine"), Samples.sshUnreachable("Debian")], select: "Alpine")
		let network = try await inspector(h, "Alpine", .device(.network))
		let regenerate = try button(network, help: "Regenerate MAC address\u{2026}")
		#expect(regenerate.label == "Regenerate MAC address\u{2026}")
		#expect(regenerate.isEnabled)

		let ssh = try await h.snapshot(
			TreeSectionProbe(harness: h, vm: h.vm("Debian")) { AnyView(TreeSSHSection(ctx: $0)) })
		let retry = try #require(
			ssh.all.first { $0.role == "AXButton" && $0.help?.hasPrefix("SSH: ") == true },
			"\(ssh.dump())")
		#expect(retry.help == "SSH: no answer on port 22 \u{2014} try again")
		#expect(retry.label == retry.help)

		// The indicator reads as one button: the state dot's word leads its name.
		let indicator = try await h.snapshot(
			VMIndicatorCluster(viewModel: h.viewModel, vm: h.vm("Debian")))
		let picker = try #require(
			indicator.all.first { $0.role == "AXButton" }, "\(indicator.dump())")
		#expect(picker.label == "Running, Debian, EFI")
		#expect(picker.help == "Debian \u{2014} Switch VM")
	}

	@Test("W3-20: the memory field's tooltip gives the exact bytes")
	func theMemoryFieldGivesTheBytes() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		let vm = h.vm("Alpine")
		let tree = try await inspector(h, "Alpine", nil)
		let field = try #require(
			tree.all.first { $0.role == "AXTextField" && $0.value == "4 GB" }, "\(tree.dump())")
		#expect(field.help == "\(vm.memoryBytes.formatted()) bytes, and a bare number means GB")
	}

	@Test("W3-27: a 16 MB log cap reads 16 MB in Max size")
	func anUnlistedCapReadsItsSize() async throws {
		let h = await UIHarness.make([Samples.kernelBoot()])
		#expect(h.vm("Kernel Lab").uartPorts?.first?.logging.maxBytes == 16 << 20)
		let tree = try await inspector(
			h, "Kernel Lab", .serial(SerialPortRef(kind: .uart, index: 0)))
		let cap = try #require(tree.control(labelled: "Max size"), "\(tree.dump())")
		#expect(cap.role == "AXPopUpButton")
		#expect(cap.text == "16 MB")
	}

	@Test("W6: a reported console names the guest OS, and SSH and safe saves read right")
	func reportedConsoleNamesTheGuestOS() async throws {
		let h = await UIHarness.make([Samples.linuxConsolesReported(), Samples.linuxSafeRun("Kali")])
		#expect(h.vm("Debian").setup?.guestOS == "debian")
		let tree = try await inspector(
			h, "Debian", .serial(SerialPortRef(kind: .console, index: 0)))
		#expect(tree.find(role: "AXStaticText", text: "Debian") != nil, "\(tree.dump())")
		#expect(tree.find(role: "AXStaticText", text: "/dev/hvc0") != nil)
		#expect(tree.find(text: "debian") == nil, "a raw os-release id as a label")
		// Any id the table doesn't know reads Guest, never itself.
		#expect(GuestOSName.display("opensuse-tumbleweed") == "openSUSE")
		#expect(GuestOSName.display("mystery-linux") == "Guest")
		#expect(GuestOSName.display(nil) == "Guest")

		let save = try await h.snapshot(SafeSaveSheet(vm: h.vm("Kali"), viewModel: h.viewModel))
		#expect(save.find(text: "The safe run carries on as the new VM, the disks it wrote "
			+ "directly move into its folder, and the original uses them from there.") != nil,
			"\(save.dump())")
		// The BSD caption sits in a collapsed disclosure, which never reaches the tree.
		let setup = try RepoFiles.text(
			"MachmanKit/Sources/MachmanDesktopUI/Inspector/GuestSetupInspector.swift")
		#expect(setup.contains("automounts over SSH"))
		#expect(setup.range(of: #"over ssh\b"#, options: .regularExpression) == nil)
	}

	@Test("H46: inspector number fields share one bordered style on their label's line")
	func numberFieldsLookTypedIn() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		let tree = try await inspector(h, "Alpine", nil)
		let field = try #require(
			tree.all.first { $0.role == "AXTextField" && $0.value == "4 GB" }, "\(tree.dump())")
		let label = try #require(tree.find(role: "AXStaticText", text: "Memory"))
		let fieldMid = try #require(field.frame?.midY)
		let labelMid = try #require(label.frame?.midY)
		#expect(abs(fieldMid - labelMid) <= 1, "Memory \(labelMid) vs its field \(fieldMid)")
		// Memory, Grow to, Width, Height and PPI: one style, so no plain field is left.
		let plain = RepoFiles.files(
			under: ["MachmanKit/Sources/MachmanDesktopUI/Inspector"], extension: "swift")
			.filter { (try? String(contentsOf: $0, encoding: .utf8))?
				.contains(".textFieldStyle(.plain)") == true }
			.map(RepoFiles.relativePath)
		#expect(plain.isEmpty, "plain number fields in \(plain)")
	}

	@Test("P11: the SSH inspector offers this Mac's public key once read")
	func theSSHInspectorReadsTheKeyOffMain() async throws {
		let dir = TestEnvironment.scratch + UUID().uuidString
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let identity = dir + "/id_ed25519"
		try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoKeyForTheTest demo@mac\n"
			.write(toFile: identity + ".pub", atomically: true, encoding: .utf8)
		var vm = Samples.linux("Alpine")
		vm.ssh?.identityFilePath = identity
		let h = await UIHarness.make([vm])
		h.viewModel.treeSelection = [.group("SSH")]
		let copy = try await OffscreenHost.withHost(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm("Alpine")),
			width: 320, height: 820
		) { hosted in
			// The read lands a few turns after the first layout, never inside it.
			for _ in 0..<20 where hosted.snapshot().find(label: Self.copyKey) == nil {
				await hosted.settle()
			}
			return hosted.snapshot().find(label: Self.copyKey)
		}
		#expect(copy?.role == "AXButton")
		#expect(copy?.isEnabled == true)
	}

	static let copyKey = "Copy this Mac\u{2019}s public key"

	// The menu itself reaches no tree until it opens; the picker draws SerialLogCaps' items.
	@Test("W3-27: the Max size menu lists Unlimited, 1, 10, 16 and 100 MB around a 16 MB cap")
	func theMaxSizeMenuKeepsAnUnlistedCap() async throws {
		let h = await UIHarness.make([Samples.kernelBoot()])
		let cap = try #require(h.vm("Kernel Lab").uartPorts?.first?.logging.maxBytes)
		let items = SerialLogCaps.items(current: cap)
		#expect(items.map(\.label) == ["Unlimited", "1 MB", "10 MB", "16 MB", "100 MB"])
		#expect(items.first { $0.bytes == cap }?.label == "16 MB")
		// Picking 10 MB leaves only the presets.
		#expect(SerialLogCaps.items(current: 10 << 20).map(\.label)
			== ["Unlimited", "1 MB", "10 MB", "100 MB"])
		#expect(SerialLogCaps.items(current: nil).count == 4)
	}

	@Test("W4-7: the disk, mount and kernel trash buttons say what they remove")
	func trashButtonsSayWhatTheyRemove() async throws {
		var ownedISO = Samples.linux("Fedora")
		ownedISO.disks[1].owned = true
		let h = await UIHarness.make(
			[Samples.linux("Alpine"), ownedISO, Samples.kernelBoot()], select: "Alpine")
		let iso = "iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso"
		let kernel = try #require(h.vm("Kernel Lab").boot.ownedKernels?.first?.path)
		for (vm, node, words) in [
			("Alpine", SidebarNode.disk("storage:system"), "Delete disk\u{2026}"),
			("Alpine", .disk(iso), "Remove disk \u{2014} the file stays"),
			("Fedora", .disk(iso), "Delete disk\u{2026}"),   // row 18: an owned ISO
			("Alpine", .mount(Samples.srcMountID), "Remove mount \u{2014} the folder stays"),
			("Kernel Lab", .kernel(kernel), "Delete file\u{2026}"),
		] {
			let tree = try await inspector(h, vm, node)
			let trash = try #require(
				tree.all.first { $0.identifier == MachmanSymbols.delete },
				"\(node): \(tree.dump())")
			#expect(trash.label == words, "\(node)")
			#expect(trash.help == words, "\(node)")
			#expect(trash.role == "AXButton")
		}
	}

	@Test("W4-10: the port's settings button and the no-display warning read names")
	func imageOnlyControlsReadNames() async throws {
		let h = await UIHarness.make(
			[Samples.linux("Alpine"), Samples.linuxNoDisplay("Debian", state: .stopped)],
			select: "Alpine")
		let serial = try await inspector(
			h, "Alpine", .serial(SerialPortRef(kind: .console, index: 0)))
		let settings = try button(serial, help: "Edit this port\u{2019}s profile in Settings")
		#expect(settings.label == "Edit this port\u{2019}s profile in Settings")

		let words = "No display device \u{2014} the window can\u{2019}t open until one is added"
		let vm = try await inspector(h, "Debian", nil)
		let warning = try #require(vm.find(label: words), "\(vm.dump())")
		#expect(warning.help == words)
		let shown = try await inspector(h, "Alpine", nil)
		#expect(shown.find(label: words) == nil)
	}

	@Test("R3W2-37: a tree row that opens offers VoiceOver's Open action")
	func anOpeningRowOffersOpen() async throws {
		let console = SerialPortRef(kind: .console, index: 0)
		let opens = try await OffscreenHost.withHost(
			HStack { Text("hvc0") }.treeRow(.serial(console), onClick: {}) { EmptyView() }
		) { $0.snapshot() }
		#expect(opens.all.contains { $0.actions == ["Open"] }, "\(opens.dump())")
		let selects = try await OffscreenHost.withHost(
			HStack { Text("hvc0") }.treeRow(.serial(console)) { EmptyView() }
		) { $0.snapshot() }
		#expect(selects.find(text: "hvc0") != nil, "\(selects.dump())")
		#expect(!selects.all.contains { !$0.actions.isEmpty }, "\(selects.dump())")
	}
}
