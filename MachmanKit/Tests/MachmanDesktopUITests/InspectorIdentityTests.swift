//
//  InspectorIdentityTests.swift
//  MachmanDesktopUITests
//
//  One inspector per entity (InspectorIdentity): selecting another entity in the tree gives
//  it a fresh inspector, so nothing typed or shown for one carries over to the next — a
//  kernel's command-line override (W1-10, P16) or a disk's typed grow (W1-11, P15). Both
//  run in one hosted InspectorView whose tree selection moves, as a person clicks rows.
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
struct InspectorIdentityTests {
	private func inspector(_ h: UIHarness, _ vm: String) -> some View {
		InspectorView(
			viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles, vm: h.vm(vm))
	}

	private func select(_ node: SidebarNode, in h: UIHarness, _ hosted: HostedView) async
		-> AXSnapshot {
		h.viewModel.treeSelection = [node]
		await hosted.settle()
		return hosted.snapshot()
	}

	@Test("W1-10: a kernel without an override shows none after one that has one")
	func anOverrideStaysWithItsKernel() async throws {
		let h = await UIHarness.make([Samples.kernelBoot()], select: "Kernel Lab")
		let kernels = h.vm("Kernel Lab").boot.ownedKernels ?? []
		let withOverride = try #require(kernels.first { $0.tag == "6.12" })
		let without = try #require(kernels.first { $0.tag == "6.6-lts" })
		let text = try #require(withOverride.overrideCommandLine)
		h.viewModel.treeSelection = [.kernel(withOverride.path)]
		try await OffscreenHost.withHost(inspector(h, "Kernel Lab"), width: 320, height: 820) {
			hosted in
			let first = hosted.snapshot()
			#expect(first.control(labelled: "Override VM command line")?.value == "1",
				"\(first.dump())")
			#expect(first.all.contains { $0.value == text }, "6.12 shows no override text")

			for node in [SidebarNode.kernel(without.path), .vmRoot, .kernel(without.path)] {
				let tree = await select(node, in: h, hosted)
				#expect(!tree.all.contains { $0.value?.contains("debug") == true },
					"\(node) shows 6.12's override: \(tree.dump())")
				if case .kernel = node {
					#expect(tree.control(labelled: "Override VM command line")?.value == "0")
				}
			}
			// An editor that kept the text would commit it as it went (debounced, and on
			// disappear): nothing may have been sent.
			try await Task.sleep(for: .milliseconds(800))
			#expect(!h.stub.calls.contains("setKernelOverride"), "\(h.stub.calls)")
		}
	}

	@Test("W1-11: a grow typed for one disk is gone when the other disk shows")
	func aTypedGrowStaysWithItsDisk() async throws {
		let h = await UIHarness.make([Samples.linuxTwoDisks()], select: "Alpine")
		h.viewModel.treeSelection = [.disk("storage:system")]
		try await OffscreenHost.withHost(inspector(h, "Alpine"), width: 320, height: 820) {
			hosted in
			var tree = hosted.snapshot()
			let field = try #require(Self.growField(tree), "\(tree.dump())")
			#expect(Self.grow(tree)?.isEnabled == false)
			#expect(await FieldTyping.type("64", intoFieldAt: field, in: hosted))
			tree = hosted.snapshot()
			#expect(Self.grow(tree)?.isEnabled == true, "typing 64 left Grow off")

			tree = await select(.disk("storage:data"), in: h, hosted)
			#expect(tree.all.contains { $0.role == "AXTextField" && $0.value == "data" },
				"the data disk's inspector isn't showing: \(tree.dump())")
			let next = try #require(Self.growField(tree))
			let value = tree.all.first { $0.role == "AXTextField" && $0.frame == next }?.value
			#expect(value == nil, "the data disk's field holds \(value ?? "")")
			#expect(Self.grow(tree)?.isEnabled == false)
		}
		#expect(!h.stub.calls.contains("resizeDisk"))
	}

	private static func grow(_ tree: AXSnapshot) -> AXSnapshot? {
		tree.find(role: "AXButton", text: "Grow")
	}

	// The Grow-to field: the text field on the Grow button's row, left of it.
	private static func growField(_ tree: AXSnapshot) -> CGRect? {
		guard let button = grow(tree)?.frame else { return nil }
		return tree.all.first {
			guard $0.role == "AXTextField", let frame = $0.frame else { return false }
			return frame.maxX <= button.minX && abs(frame.midY - button.midY) < 12
		}?.frame
	}

	// Q2: every inspector field over a served value follows it when it changes elsewhere;
	// the session's Name was the copy without the resync.
	@Test("Q2: the session inspector's Name follows a rename made in the tree")
	func theSessionNameFollowsARename() async throws {
		let h = await UIHarness.make(select: "Debian")
		let ref = SSHSessionRef(title: "Session 1")
		h.terminals.renameSSHSession(vm: "Debian", ref: ref, to: "Build")
		let (before, after) = try await OffscreenHost.withHost(
			SSHSessionInspector(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm("Debian"), ref: ref),
			width: 320, height: 600
		) { hosted in
			let before = hosted.snapshot()
			h.terminals.renameSSHSession(vm: "Debian", ref: ref, to: "Deploy")
			await hosted.settle()
			return (before, hosted.snapshot())
		}
		let field: (AXSnapshot) -> String? = {
			$0.all.first { $0.role == "AXTextField" }?.value
		}
		#expect(field(before) == "Build", "\(before.dump())")
		#expect(field(after) == "Deploy", "the Name field kept the old name: \(after.dump())")
	}
}
