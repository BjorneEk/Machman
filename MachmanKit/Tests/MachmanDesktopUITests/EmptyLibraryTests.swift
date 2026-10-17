//
//  EmptyLibraryTests.swift
//  MachmanDesktopUITests
//
//  The window before the first VM exists, read from the real views hosted offscreen (N5): the
//  sidebar's button reads "New VM…" (it opens the template chooser, as ⌘N does, rather than
//  making a Default VM without asking) and the detail pane says there are no VMs yet rather
//  than asking for a selection there is nothing to make.
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
struct EmptyLibraryTests {
	@Test("N5: with no VMs the window offers New VM… and says No VMs yet")
	func theEmptyWindowOffersTheChooser() async throws {
		let h = await UIHarness.make([])
		let (sidebar, pressed) = try await OffscreenHost.withHost(
			NoVMSidebar(viewModel: h.viewModel), width: 260
		) { hosted in
			let tree = hosted.snapshot()
			let pressed = Self.press(label: "New VM\u{2026}", under: hosted.host)
			await hosted.settle()
			return (tree, pressed)
		}
		let button = try #require(
			sidebar.find(role: "AXButton", text: "New VM\u{2026}"), "\(sidebar.dump())")
		#expect(button.isEnabled)
		#expect(sidebar.find(text: "No VMs yet") != nil)
		// The press asks for the template chooser, as ⌘N does; it makes no VM by itself.
		#expect(pressed)
		#expect(h.viewModel.newVMChooserRequested)
		#expect(!h.stub.calls.contains("createVM"), "\(h.stub.calls)")
		let detail = try await h.snapshot(
			VMTabContainerView(viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles),
			width: 600, height: 400)
		#expect(detail.find(text: "No VMs yet") != nil, "\(detail.dump())")
		#expect(detail.find(text: "Select a VM") == nil)
	}

	// Presses the live element labelled `label` (THGuestSetupCaptionTests' walk: SwiftUI's
	// nodes answer the NSAccessibility getters without conforming, so each is checked first).
	private static func press(label: String, under root: NSObject) -> Bool {
		var queue: [NSObject] = [root]
		var seen = 0
		while !queue.isEmpty, seen < AXSnapshot.maxNodes {
			let node = queue.removeFirst()
			seen += 1
			let name = ["accessibilityLabel", "accessibilityTitle"].compactMap { getter in
				node.responds(to: NSSelectorFromString(getter))
					? node.value(forKey: getter) as? String : nil
			}
			let press = NSSelectorFromString("accessibilityPerformPress")
			if name.contains(label), node.responds(to: press) {
				_ = node.perform(press)
				return true
			}
			if node.responds(to: NSSelectorFromString("accessibilityChildren")),
				let kids = node.value(forKey: "accessibilityChildren") as? [Any] {
				queue += kids.compactMap { $0 as? NSObject }
			}
		}
		return false
	}
}
