//
//  OffscreenHostTests.swift
//  MachmanDesktopUITests
//
//  The offscreen host's own proof: a hosted view lays out at its fitting size in a window
//  that never reaches the screen, the host-quiet check names every kind of breach, and the
//  tripwires (the app, the window) swallow what would reach the user and report it.
//

import AppKit
import SwiftUI
import Testing
import MachmanTestSupport

// L1: tooling self-tests (a never-ordered window in the test process; nothing is shown).
@MainActor
struct OffscreenHostTests {
	@Test("Q18: an offscreen host sizes a view to fit and never orders its window")
	func hostsAtFittingSize() async throws {
		let view = VStack {
			Text("Offscreen")
			Button("Press") {}
		}
		.padding(20)
		let checked = try await OffscreenHost.withHost(view) { hosted in
			#expect(hosted.bounds.width > 0 && hosted.bounds.height > 0)
			#expect(hosted.bounds.width < 1200, "the width is the fitting one, not the initial")
			#expect(!hosted.window.isVisible)
			#expect(NSApp is HostQuietApplication)
			#expect(NSApp.activationPolicy() == .prohibited)
			#expect(!NSApp.isActive)
			// The settle relies on a live main run loop handing SwiftUI its turns.
			#expect(RunLoop.main.currentMode != nil)
			return true
		}
		#expect(checked)
	}

	@Test("Q18: the host-quiet check reports each breach of an injected probe")
	func reportsInjectedBreaches() async throws {
		var keys = ["Existing"]
		let probe = HostQuiet.Probe(
			visibleWindowCount: { 1 }, onScreenWindowCount: { 2 }, isActive: { true },
			policy: { .regular }, defaultsKeys: { keys })
		let baseline = HostQuiet.baseline(probe)
		keys.append("Added")
		let breaches = HostQuiet.breaches(since: baseline, probe: probe)
		#expect(breaches.count == 5, "\(breaches)")
		#expect(breaches.contains { $0.contains("visible") })
		#expect(breaches.contains { $0.contains("on screen") })
		#expect(breaches.contains { $0.contains("active app") })
		#expect(breaches.contains { $0.contains(".regular") })
		#expect(breaches.contains { $0.contains("added: Added") })

		let live = try await OffscreenHost.exclusively {
			HostQuiet.breaches(since: HostQuiet.baseline())
		}
		#expect(live.isEmpty, "\(live)")
	}

	@Test("Q18: the tripwire application swallows modals, activation and a regular policy")
	func tripwireSwallowsWhatReachesTheUser() async throws {
		try await OffscreenHost.exclusively {
			try #require(NSApp is HostQuietApplication)
			_ = HostQuietApplication.takeBreaches()
			#expect(!NSApp.setActivationPolicy(.regular))   // host-quiet: provokes the tripwire
			#expect(NSApp.activationPolicy() == .prohibited)
			NSApp.activate()   // host-quiet: provokes the tripwire
			let window = HostWindow(
				contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
				backing: .buffered, defer: true)
			window.isReleasedWhenClosed = false
			#expect(NSApp.runModal(for: window) == .cancel)   // host-quiet: provokes the tripwire
			window.close()
			let breaches = HostQuietApplication.takeBreaches()
			#expect(breaches.count == 3, "\(breaches)")
			#expect(!NSApp.isActive)
			#expect(!window.isVisible)
		}
	}

	@Test("Q18: a breach recorded outside a host fails the next host")
	func earlierBreachFailsTheNextHost() async throws {
		try await OffscreenHost.exclusively {
			_ = HostQuietApplication.takeBreaches()
			NSApp.activate()   // host-quiet: provokes the tripwire
			let error = await #expect(throws: OffscreenHost.ReachedScreen.self) {
				try await OffscreenHost.withHost(Text("Next")) { _ in }
			}
			#expect(error?.breaches == ["before this host: NSApp.activate() was called"])
		}
	}

	@Test("Q18: a hosted window refuses to be ordered")
	func hostedWindowRefusesOrdering() async throws {
		var hostedWindow: NSWindow?
		let error = await #expect(throws: OffscreenHost.ReachedScreen.self) {
			try await OffscreenHost.withHost(Text("Ordered?")) { hosted in
				try #require(hosted.window is HostWindow)
				hostedWindow = hosted.window
				hosted.window.makeKeyAndOrderFront(nil)   // host-quiet: provokes the tripwire
			}
		}
		#expect(error?.breaches.contains { $0.contains("makeKeyAndOrderFront") } == true,
			"\(String(describing: error))")
		#expect(hostedWindow?.isVisible == false)
	}
}
