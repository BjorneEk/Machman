//
//  ProbeSelfTests.swift
//  MachmanDesktopUITests
//
//  The r3-te probes' own proof: a tree-section probe lays a section's rows out with its
//  groups open, and typing into a hosted text field reaches the SwiftUI binding behind it —
//  without a key window, a first responder or an event.
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: tooling self-tests (views hosted offscreen; nothing is shown).
@MainActor
struct ProbeSelfTests {
	@Test("Q18: a tree-section probe lays out its section's rows, groups open")
	func aSectionProbeShowsItsRows() async throws {
		let h = await UIHarness.make([Samples.linuxWithMounts()])
		let tree = try await h.snapshot(
			TreeSectionProbe(harness: h, vm: h.vm("Debian")) {
				AnyView(TreeStorageSection(ctx: $0))
			})
		#expect(tree.find(text: "Disks") != nil, "\(tree.dump())")
		#expect(tree.find(text: "Mounts") != nil)
		#expect(tree.find(text: "system") != nil, "the Disks group is closed")
		// A path outside the (fake) home reads in full.
		#expect(tree.find(text: "/Users/demo/src") != nil, "the Mounts group is closed")
		#expect(tree.find(label: "Collapse Mounts") != nil)
	}

	@Test("Q18: typing into a hosted text field reaches its SwiftUI binding")
	func typingReachesTheBinding() async throws {
		let echoed = try await OffscreenHost.withHost(TypingSample(), width: 240) { hosted in
			let field = try #require(
				hosted.snapshot().findAll { $0.role == "AXTextField" }.first?.frame)
			#expect(await FieldTyping.type("64", intoFieldAt: field, in: hosted))
			return hosted.snapshot().find(text: "echo:64") != nil
		}
		#expect(echoed)
	}
}

private struct TypingSample: View {
	@State private var text = ""

	var body: some View {
		VStack {
			TextField("x", text: $text)
			Text("echo:\(text)")
		}
		.padding(10)
	}
}
