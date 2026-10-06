//
//  PasteboardSeamTests.swift
//  MachmanDesktopUITests
//
//  The app's pasteboard watch (PasteboardWatch.general, EntityClipboard+Pasteboard.swift) reads
//  nothing under test mode: VMNavigationView hosted offscreen builds the device tree on it, and
//  a read of NSPasteboard.general there would reach the user's pasteboard from test.sh. The
//  .dev and Release suites, and every Release build, read the pasteboard as before.
//

import Testing
import MachmanAPI
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: a test-mode seam (TestModeSeamInventoryTests lists it).
struct PasteboardSeamTests {
	static let labSuite = MachmanTestMode.suitePrefix + "abc1"

	@Test("Q18: the app's pasteboard watch reads the pasteboard outside test mode")
	func theWatchReadsThePasteboardOutsideTestMode() {
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			for debugBuild in [true, false] {
				let testMode = MachmanTestMode.isActive(suiteID: suite, debugBuild: debugBuild)
				#expect(PasteboardWatch.generalSource(testMode: testMode) == .generalPasteboard)
			}
		}
		let release = MachmanTestMode.isActive(suiteID: Self.labSuite, debugBuild: false)
		#expect(PasteboardWatch.generalSource(testMode: release) == .generalPasteboard)
		let lab = MachmanTestMode.isActive(suiteID: Self.labSuite, debugBuild: true)
		#expect(PasteboardWatch.generalSource(testMode: lab) == .nothing)
	}

	@Test("Q18: under test.sh the app's pasteboard watch is the one that reads nothing")
	@MainActor
	func underTestModeTheWatchReadsNothing() {
		#expect(MachmanTestMode.isActive)
		#expect(PasteboardWatch.generalSourceInThisProcess == .nothing)
		let watch = PasteboardWatch.general   // host-quiet: the seam under test, inert here
		watch.refresh()
		#expect(!watch.snapshot.canPasteAnything)
	}
}
