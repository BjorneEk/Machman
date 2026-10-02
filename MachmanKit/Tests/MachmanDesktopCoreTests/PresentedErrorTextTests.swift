//
//  PresentedErrorTextTests.swift
//  MachmanDesktopCoreTests
//
//  E28: an NSError reached the desktop's alerts as "Error Domain=NSCocoaErrorDomain Code=4 …"
//  (CocoaError isn't a LocalizedError to a cast). Alerts read the error's own sentence.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct PresentedErrorTextTests {
	@Test func aCocoaErrorReadsItsLocalizedDescription() async {
		let h = await DesktopHarness.make()
		let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/x/notes.txt"])
		h.viewModel.present(error, while: "Saving")
		#expect(h.viewModel.presentedError?.title == "Saving failed")
		#expect(h.viewModel.presentedError?.message == error.localizedDescription)
		#expect(h.viewModel.presentedError?.message.contains("Error Domain") == false)
	}
}
