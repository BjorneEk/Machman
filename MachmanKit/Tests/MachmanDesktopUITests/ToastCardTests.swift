//
//  ToastCardTests.swift
//  MachmanDesktopUITests
//
//  The corner overlay's cards and toasts, hosted offscreen: a progress card's title and
//  its failure carry their whole text as tooltips and the failure wraps to three lines
//  (W3-40, L4), a long warning toast wraps within 340 pt and keeps the whole message on
//  hover (W3-41, F6), a toast offers nothing to click (W3-63), and a pushed toast reaches
//  VoiceOver once (H56). Hover itself doesn't render; the holding rule is ToastTests'
//  (aHoveredToastStays).
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
struct ToastCardTests {
	static let warning = "Debian: " + Samples.screenRecordingWarning

	private var stack: some View {
		ToastStack(toasts: [MachmanToast(symbol: MachmanSymbols.warning, message: Self.warning)])
	}

	@Test("W3-40: a card's title and failure carry tooltips; the failure wraps to 3")
	func aFailedCardWrapsWithTooltips() async throws {
		let h = await UIHarness.make()
		let failed = Samples.failedImport()
		let running = Samples.copyOperation()
		let title = failed.displayTitle
		let outcome = try #require(failed.outcomeText)
		// The overlay's own mapping (NotificationOverlay → OperationInfo+Display). A finished
		// card lingers 5 s, so the operations arrive once the overlay is up.
		try await OffscreenHost.withHost(
			NotificationOverlay(viewModel: h.viewModel, operations: h.operations),
			width: 800, height: 600
		) { hosted in
			h.stub.emit(.operationChanged(op: failed))
			h.stub.emit(.operationChanged(op: running))
			#expect(await eventually(timeout: .seconds(4)) {
				hosted.snapshot().find(text: outcome) != nil
					&& hosted.snapshot().find(text: "13 GB of 32 GB") != nil
			})
			await hosted.settle()
			let tree = hosted.snapshot()
			let titleText = try #require(tree.find(text: title), "\(tree.dump())")
			#expect(titleText.help == title)
			let phase = try #require(tree.find(text: outcome), "\(tree.dump())")
			#expect(phase.help == outcome)
			// One caption line, from the running card's one-line phase.
			let line = try #require(tree.find(text: "13 GB of 32 GB")?.frame?.height)
			let height = try #require(phase.frame?.height)
			#expect(height > line + 1, "the failure fits one line, so the row proves nothing")
			#expect(height <= 3 * line + 2, "\(height) for a line of \(line)")
		}
	}

	@Test("W3-41: a long warning toast wraps within 340 pt and keeps it on hover")
	func aLongToastWraps() async throws {
		let tree = try await OffscreenHost.withHost(stack, width: 800, height: 400) {
			$0.snapshot()
		}
		let text = try #require(tree.find(text: Self.warning), "\(tree.dump())")
		let frame = try #require(text.frame)
		#expect(frame.width <= 340.5, "\(frame)")   // the row: about 340 pt
		#expect(frame.height > 30, "the message didn't wrap: \(frame)")
		#expect(tree.all.contains { $0.help == Self.warning }, "no whole-text tooltip")
		// The VM's name leads (F6).
		#expect(Self.warning.hasPrefix("Debian: "))
	}

	@Test("H56: one pushed toast gives one VoiceOver announcement with its text")
	func aPushedToastIsAnnouncedOnce() async throws {
		let h = await UIHarness.make()
		let heard = Heard()
		try await OffscreenHost.withHost(
			NotificationOverlay(viewModel: h.viewModel, operations: h.operations)
				.environment(\.toastAnnouncer, ToastAnnouncer { heard.posts.append($0) }),
			width: 800, height: 600
		) { hosted in
			#expect(heard.posts.isEmpty, "said something before any toast: \(heard.posts)")
			h.viewModel.pushToast(
				symbol: MachmanSymbols.serialConsole, message: "Removed console port")
			#expect(await eventually { !heard.posts.isEmpty })
			await hosted.settle()
			#expect(heard.posts == [
				ToastAnnouncement(text: "Removed console port", urgent: false),
			])
		}
	}

	@MainActor
	private final class Heard {
		var posts: [ToastAnnouncement] = []
	}

	@Test("W3-63: a toast offers nothing to click")
	func aToastOffersNothingToClick() async throws {
		let tree = try await OffscreenHost.withHost(stack, width: 800, height: 400) {
			$0.snapshot()
		}
		#expect(tree.find(text: Self.warning) != nil)
		#expect(tree.findAll { $0.role == "AXButton" }.isEmpty, "\(tree.dump())")
		#expect(tree.all.allSatisfy { $0.actions.isEmpty }, "\(tree.dump())")
	}
}
