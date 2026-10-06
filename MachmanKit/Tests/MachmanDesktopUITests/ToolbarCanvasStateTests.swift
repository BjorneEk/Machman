//
//  ToolbarCanvasStateTests.swift
//  MachmanDesktopUITests
//
//  The toolbar's and the canvas's controls for each VM state, from the real views hosted
//  offscreen: Start follows a safe policy and the shields show only in a safe run (15),
//  the indicator's tooltip keeps the whole name (W3-37), a stopping VM keeps Force Stop
//  (W3-38), an unreached VM waits (R3W2-8, P37), an installing Mac can't start from the
//  canvas (W3-36), a failed install's message keeps two lines (W3-32), a narrow pane keeps
//  Starting… (W4-32), and the image-only controls read their names (W4-27, H32).
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
struct ToolbarCanvasStateTests {
	static let safeHelp = "Safe mode \u{2014} changes are discarded on stop"

	private func toolbar(_ h: UIHarness, _ name: String) async throws -> AXSnapshot {
		try await h.snapshot(StartStopGroup(viewModel: h.viewModel, vm: h.vm(name)))
	}

	private func preview(
		_ h: UIHarness, _ name: String, width: CGFloat = 600, height: CGFloat = 480
	) async throws -> AXSnapshot {
		try await h.snapshot(
			VMPreviewTabView(vm: h.vm(name), viewModel: h.viewModel), width: width,
			height: height)
	}

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

	private func shields(_ tree: AXSnapshot) -> Int {
		tree.all.filter { $0.help == Self.safeHelp }.count
	}

	// MARK: - 15

	@Test("15: Start reads Start Safe or Start Headless and Safe under a safe policy")
	func startNamesTheSafePolicy() async throws {
		let h = await UIHarness.make(
			[Samples.linuxSafePolicy("Alpine"), Samples.linuxHeadlessSafePolicy("Kali")])
		let safe = try await toolbar(h, "Alpine")
		#expect(safe.find(label: "Start Safe")?.isEnabled == true, "\(safe.dump())")
		let headless = try await toolbar(h, "Kali")
		#expect(headless.find(label: "Start Headless and Safe")?.isEnabled == true,
			"\(headless.dump())")
		// The explicit safe segment is the same on both.
		let segment = "Start Safe \u{2014} run on a discardable shadow"
		#expect(safe.find(label: segment) != nil && headless.find(label: segment) != nil)
	}

	@Test("15: shields show on the picker, inspector and preview only in a safe run")
	func shieldsOnlyInASafeRun() async throws {
		let h = await UIHarness.make(
			[Samples.linuxSafeRun("Debian"), Samples.linux("Alpine", state: .running)])
		let picker = try await h.snapshot(VMPickerPopover(viewModel: h.viewModel))
		let pickerRows = picker.findAll { $0.help == Self.safeHelp }
		#expect(pickerRows.count == 1, "only Debian's row: \(picker.dump())")

		let safeInspector = try await inspector(h, "Debian", nil)
		#expect(shields(safeInspector) >= 1, "\(safeInspector.dump())")
		#expect(safeInspector.find(text: "Changes are discarded on stop") != nil)
		#expect(shields(try await preview(h, "Debian")) >= 1)

		let plainInspector = try await inspector(h, "Alpine", nil)
		#expect(shields(plainInspector) == 0)
		#expect(plainInspector.find(text: "Changes are discarded on stop") == nil)
		#expect(shields(try await preview(h, "Alpine")) == 0)
	}

	@Test("15: the disk and mount safe-run toggles both explain themselves")
	func safeRunTogglesExplainThemselves() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		let disk = try await inspector(h, "Alpine", .disk("storage:system"))
		let shadow = try #require(disk.control(labelled: "Shadow in safe runs"),
			"\(disk.dump())")
		#expect(shadow.help == "Safe runs write to a discardable shadow of this disk")

		let mount = try await inspector(h, "Alpine", .mount(Samples.srcMountID))
		let attach = try #require(mount.control(labelled: "Attach in safe runs"),
			"\(mount.dump())")
		// Fails until the open bug H53 (the toggle is inverted and has no tooltip) is fixed:
		// the src mount is safe, so a safe run leaves it out and the toggle must read off.
		#expect(attach.value == "0", "Attach in safe runs reads on for a mount safe runs omit")
		#expect(attach.help?.isEmpty == false, "Attach in safe runs has no tooltip")
	}

	// MARK: - Toolbar states

	@Test("W3-37: the VM indicator's tooltip carries the whole name and Switch VM")
	func theIndicatorKeepsTheWholeName() async throws {
		let long = Samples.longNamedLinux()
		let h = await UIHarness.make([long])
		let tree = try await h.snapshot(VMIndicatorCluster(viewModel: h.viewModel, vm: long))
		let picker = try #require(tree.all.first { $0.role == "AXButton" }, "\(tree.dump())")
		#expect(picker.help == "\(long.name) \u{2014} Switch VM")
	}

	@Test("W3-38: a stopping VM's toolbar reads Stopping… beside Force Stop")
	func aStoppingVMKeepsForceStop() async throws {
		let h = await UIHarness.make([Samples.stoppingLinux()])
		let tree = try await toolbar(h, "Debian")
		#expect(tree.find(text: "Stopping\u{2026}") != nil, "\(tree.dump())")
		let force = try #require(tree.find(label: "Force Stop"))
		#expect(force.role == "AXButton")
		#expect(force.isEnabled)
		#expect(tree.find(label: "Shut Down") == nil)
	}

	@Test("R3W2-8: an unreached VM's toolbar waits with Force Stop; its canvas Start dims")
	func anUnreachedVMWaits() async throws {
		let h = await UIHarness.make([Samples.unreached()])
		let tree = try await toolbar(h, "Debian")
		#expect(tree.all.contains { $0.help == VMInfo.unreachedHelp }, "\(tree.dump())")
		#expect(tree.find(label: "Force Stop")?.isEnabled == true)
		#expect(tree.find(label: "Start") == nil)
		#expect(tree.find(label: "Start Safe \u{2014} run on a discardable shadow") == nil)
		let canvas = try await preview(h, "Debian")
		let start = try #require(canvas.find(label: "Start Debian"), "\(canvas.dump())")
		#expect(!start.isEnabled)
	}

	@Test("W3-36: a Mac that is installing dims the canvas Start button")
	func anInstallingMacCantStart() async throws {
		let h = await UIHarness.make([Samples.macOS("Sequoia")])
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: Samples.downloadingMacInstall()))
		#expect(await eventually { h.viewModel.isInstalling(h.vm("Sequoia")) })
		let canvas = try await preview(h, "Sequoia")
		let start = try #require(canvas.find(label: "Start Sequoia"), "\(canvas.dump())")
		#expect(!start.isEnabled)
		#expect(canvas.find(role: "AXButton", text: "Cancel") != nil, "the install banner")
	}

	// MARK: - Layout

	@Test("W3-32: a failed install's message keeps two lines and the whole text on hover")
	func aFailedInstallKeepsTwoLines() async throws {
		let mac = Samples.macOSFailedInstall()
		let message = try #require(mac.boot.macInstallState?.message)
		let h = await UIHarness.make([mac])
		let tree = try await h.snapshot(
			VStack(spacing: 0) {
				Text("Line").font(.callout)
				VMPreviewTabView(vm: h.vm("Sequoia"), viewModel: h.viewModel)
			}, width: 600, height: 520)
		let line = try #require(tree.find(text: "Line")?.frame?.height)
		let problem = try #require(
			tree.all.first { $0.help == message && $0.frame != nil }, "\(tree.dump())")
		let height = try #require(problem.frame?.height)
		#expect(height > line + 1, "the message fits one line, so the row proves nothing")
		#expect(height <= 2 * line + 6, "\(height) for a line of \(line)")
	}

	@Test("W4-32: a starting VM keeps Starting… inside a 120 pt pane")
	func startingFitsANarrowPane() async throws {
		let h = await UIHarness.make([Samples.kernelBoot(state: .starting)])
		let tree = try await preview(h, "Kernel Lab", width: 120, height: 200)
		let starting = try #require(
			tree.findAll { $0.text == "Starting\u{2026}" }.compactMap(\.frame).first,
			"\(tree.dump())")
		#expect(starting.minX >= 0 && starting.maxX <= 120.5, "\(starting)")
	}

	// MARK: - Names

	@Test("W4-27: Start, Add and Back read their names, never a symbol")
	func imageControlsReadTheirNames() async throws {
		var headless = Samples.linux("Kali")
		headless.startPolicy = StartPolicy(windowed: false)
		let h = await UIHarness.make([Samples.linux("Alpine"), headless])
		#expect(try await toolbar(h, "Alpine").find(label: "Start") != nil)
		#expect(try await toolbar(h, "Kali").find(label: "Start Headless") != nil)
		let add = try await h.snapshot(AddButton(viewModel: h.viewModel, vm: h.vm("Alpine")))
		#expect(add.find(label: "Add Disk, Mount, Serial Port, or Device") != nil,
			"\(add.dump())")
		#expect(try await preview(h, "Alpine").find(label: "Start Alpine") != nil)
		let source = try await h.snapshot(
			VMPickerPopover(viewModel: h.viewModel, macSource: true))
		let back = try #require(source.find(label: "Back"), "\(source.dump())")
		#expect(back.role == "AXButton")
		// No control reads as its symbol's name.
		for tree in [add, source] {
			for button in tree.findAll(where: { $0.role == "AXButton" }) {
				#expect(button.label != button.identifier, "\(button)")
			}
		}
	}
}
