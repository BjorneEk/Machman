//
//  InspectorGatingTests.swift
//  MachmanDesktopUITests
//
//  Which inspector controls a VM's state leaves live, read from InspectorView hosted
//  offscreen over the sample states: the Default start toggles (14a, and their fit at the
//  inspector's floor), a running VM's Name (W2-18, P14), a not-responding VM's disk (W3-21),
//  an outdated vmhost's lock and what stays live inside it (W3-60, W4-2, E22), an unreached
//  VM's actions waiting for the agent (R3W2-44, P37) and a boot mode a newer Machman wrote
//  (R3W2-45, C11). The lock and every reason are the views' own; nothing is pressed.
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
struct InspectorGatingTests {
	static let card = "H52: Default start offers Safe mode while Start at login is on (and the "
		+ "reverse), then the daemon refuses the pair with an error alert"

	// The inspector for `vm` with `node` selected in the tree.
	private func inspector(
		_ h: UIHarness, _ vm: String, _ node: SidebarNode?, width: CGFloat = 320
	) async throws -> AXSnapshot {
		h.viewModel.select(name: vm)
		h.viewModel.treeSelection = node.map { [$0] } ?? []
		return try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm(vm)),
			width: width, height: 820)
	}

	private func element(
		_ tree: AXSnapshot, _ text: String, role: String? = nil,
		sourceLocation: SourceLocation = #_sourceLocation
	) throws -> AXSnapshot {
		let found = tree.all.first { ($0.text == text || $0.label == text)
			&& (role == nil || $0.role == role) && $0.role != "AXStaticText" }
		return try #require(found, "no \(text): \(tree.dump())", sourceLocation: sourceLocation)
	}

	// A Form row's control by the label beside it (FormControls).
	private func control(
		_ tree: AXSnapshot, labelled title: String,
		sourceLocation: SourceLocation = #_sourceLocation
	) throws -> AXSnapshot {
		try #require(tree.control(labelled: title),
			"no control labelled \(title): \(tree.dump())", sourceLocation: sourceLocation)
	}

	// MARK: - Default start

	@Test("14a: Safe mode and Start at login rule each other out")
	func safeModeAndAutostartRuleEachOtherOut() async throws {
		let h = await UIHarness.make([Samples.linuxAutostart(), Samples.linuxSafePolicy("Kali")])
		let autostart = try await inspector(h, "Alpine", nil)
		let safe = try await inspector(h, "Kali", nil)
		// The samples are what they say: each VM has the other toggle on.
		#expect(try control(autostart, labelled: "Start at login").value == "1")
		#expect(try control(safe, labelled: "Safe mode").value == "1")
		let safeToggle = try control(autostart, labelled: "Safe mode")
		let loginToggle = try control(safe, labelled: "Start at login")
		// The daemon refuses the pair (“A safe run can’t start automatically”); the toggles
		// used to dim each other with that reason and no longer do.
		withKnownIssue(Comment(rawValue: Self.card)) {
			#expect(!safeToggle.isEnabled, "Safe mode stays on offer under Start at login")
			#expect(safeToggle.help?.isEmpty == false)
			#expect(!loginToggle.isEnabled, "Start at login stays on offer under Safe mode")
			#expect(loginToggle.help?.isEmpty == false)
		}
	}

	@Test("RunDefaults narrow width: the Default start toggles fit at the 250 pt floor")
	func defaultStartFitsTheFloor() async throws {
		let h = await UIHarness.make([Samples.linuxAutostart()])
		let width = MainWindowLayout.inspector.min
		#expect(width == 250)
		let tree = try await inspector(h, "Alpine", nil, width: width)
		for title in ["Open window", "Safe mode", "Start at login"] {
			let toggle = try #require(try control(tree, labelled: title).frame)
			let label = try #require(tree.find(role: "AXStaticText", text: title)?.frame)
			for frame in [toggle, label] {
				#expect(frame.minX >= 0 && frame.maxX <= width + 0.5, "\(title): \(frame)")
			}
			#expect(label.maxX <= toggle.minX, "\(title) overlaps its switch")
		}
	}

	// MARK: - Running, not responding

	@Test("W2-18: a running VM's Name field is dimmed with the reason")
	func aRunningVMsNameIsDimmed() async throws {
		let h = await UIHarness.make()
		let tree = try await inspector(h, "Debian", nil)
		let name = try #require(tree.all.first { $0.role == "AXTextField" && $0.value == "Debian" },
			"\(tree.dump())")
		#expect(!name.isEnabled)
		#expect(name.help == "Stop the VM to rename it")
	}

	@Test("W3-21: a not-responding VM's disk Name and Grow say to stop it first")
	func aStalledVMsDiskWaits() async throws {
		let h = await UIHarness.make(Samples.libraryWithStalledHost())
		let tree = try await inspector(h, "Debian", .disk("storage:system"))
		let name = try #require(tree.all.first { $0.role == "AXTextField" && $0.value == "system" },
			"\(tree.dump())")
		#expect(!name.isEnabled)
		#expect(name.help == "Stop the VM to rename its disks")
		let grow = try element(tree, "Grow", role: "AXButton")
		#expect(!grow.isEnabled)
		#expect(tree.all.contains { $0.help == "Stop the VM to grow its disks" },
			"\(tree.dump())")
	}

	// MARK: - Outdated vmhost (E22)

	@Test("W3-60: an outdated VM keeps copy, reveal, guides and profile live")
	func anOutdatedVMKeepsItsReadsLive() async throws {
		let h = await UIHarness.make(Samples.libraryWithOutdatedHost())
		let disk = try await inspector(h, "Debian", .disk("storage:system"))
		let reason = try #require(h.vm("Debian").restartToUpdate)
		#expect(disk.all.contains { $0.text == reason }, "no lock banner: \(disk.dump())")
		#expect(try element(disk, "Copy path", role: "AXButton").isEnabled)
		#expect(try element(disk, "Show in Finder", role: "AXButton").isEnabled)
		#expect(!(try control(disk, labelled: "Shadow in safe runs").isEnabled))
		#expect(!(try control(disk, labelled: "Enabled").isEnabled))
		let trash = try #require(disk.all.first { $0.identifier == MachmanSymbols.delete })
		#expect(!trash.isEnabled)

		let console = SerialPortRef(kind: .console, index: 0)
		let serial = try await inspector(h, "Debian", .serial(console))
		#expect(try element(serial, "Setup Guide\u{2026}", role: "AXButton").isEnabled)
		let profile = try control(serial, labelled: "Profile")
		#expect(profile.role == "AXPopUpButton")
		#expect(profile.text == h.profiles.profile(vm: "Debian", ref: console).name)
		#expect(profile.isEnabled)
		let mode = try control(serial, labelled: "Mode")
		#expect(mode.role == "AXPopUpButton")
		#expect(!mode.isEnabled)

		let network = try await inspector(h, "Debian", .device(.network))
		#expect(try element(network, "Re-run address discovery", role: "AXButton").isEnabled)
		let regenerate = try #require(
			network.all.first { $0.identifier == MachmanSymbols.regenerate && $0.help != nil
				&& $0.help != "Re-run address discovery" }, "\(network.dump())")
		#expect(!regenerate.isEnabled)

		let vm = try await inspector(h, "Debian", nil)
		let memory = try #require(vm.all.first {
			$0.role == "AXTextField" && $0.help?.hasSuffix("a bare number means GB") == true
		}, "\(vm.dump())")
		#expect(!memory.isEnabled)
		let stepper = try #require(vm.all.first { $0.role == "AXIncrementor" }, "\(vm.dump())")
		#expect(!stepper.isEnabled)
	}

	@Test("W4-2: the mount Setup Guide opens on a VM run by an older vmhost")
	func theMountGuideStaysLive() async throws {
		let h = await UIHarness.make(Samples.libraryWithOutdatedHost())
		let tree = try await inspector(h, "Debian", .mount(Samples.srcMountID))
		let guide = try element(tree, "Setup Guide\u{2026}", role: "AXButton")
		#expect(guide.isEnabled)
		#expect(guide.help == "How to reach this folder from the guest")
		#expect(!(try control(tree, labelled: "Enabled").isEnabled))
	}

	// MARK: - Unreached, newer boot mode

	@Test("R3W2-44: an unreached VM's MAC, install and bootloader wait for the agent")
	func anUnreachedVMWaitsForTheAgent() async throws {
		let h = await UIHarness.make(
			Samples.libraryWithUnreachedHost().filter { $0.name != "Sequoia" }
				+ [Samples.macOSUnfinishedUnreached()])
		let network = try await inspector(h, "Debian", .device(.network))
		let regenerate = try #require(
			network.all.first { $0.help == VMInfo.unreachedHelp && $0.role == "AXButton" },
			"\(network.dump())")
		#expect(!regenerate.isEnabled)
		#expect(regenerate.identifier == MachmanSymbols.regenerate)

		let mac = try await inspector(h, "Sequoia", nil)
		let install = try element(mac, "Install macOS\u{2026}", role: "AXButton")
		#expect(!install.isEnabled)
		#expect(install.help == VMInfo.unreachedHelp)
		let bootloader = try #require(
			mac.all.first { $0.role == "AXPopUpButton" && $0.help == VMInfo.unreachedHelp },
			"\(mac.dump())")
		#expect(!bootloader.isEnabled)
	}

	@Test("R3W2-45: a newer boot mode reads Bootloader Unknown with no nested toggle")
	func aNewerBootModeReadsUnknown() async throws {
		let h = await UIHarness.make([Samples.newerBootMode()])
		let tree = try await inspector(h, "Alpine", nil)
		#expect(tree.find(text: "Unknown") != nil, "\(tree.dump())")
		#expect(tree.all.contains { $0.help == BootInfo.newerModeReason }, "\(tree.dump())")
		#expect(tree.find(text: "Allow nested virtualization") == nil)
		#expect(!tree.all.contains { $0.role == "AXPopUpButton" && $0.text == "EFI" })
	}
}
