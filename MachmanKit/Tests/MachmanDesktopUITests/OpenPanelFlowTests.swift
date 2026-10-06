//
//  OpenPanelFlowTests.swift
//  MachmanDesktopUITests
//
//  The add flows' open panels, answered by the test (OpenPanels, Q21): New VM ▸ macOS ▸ From
//  an IPSW File… creates the VM only once a file is picked and installs from it, and Cancel
//  leaves nothing behind (W3-19, H21). No panel opens and no view is hosted.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@MainActor
struct OpenPanelFlowTests {
	private static func answering(
		_ url: URL?, asked: @escaping (OpenPanelRequest) -> Void = { _ in }
	) -> OpenPanels {
		OpenPanels { request, answer in
			asked(request)
			answer(url)
		}
	}

	@Test("W3-19: cancelling the IPSW panel creates no VM, a picked file creates and installs one")
	func theIPSWPanelCreatesOnlyOnAPick() async throws {
		let h = await UIHarness.make([Samples.linux("Alpine")])
		var asked: [OpenPanelRequest] = []
		AddFlows.newMacFromFile(
			viewModel: h.viewModel, panels: Self.answering(nil) { asked.append($0) })
		try await Task.sleep(for: .milliseconds(200))
		#expect(asked == [OpenPanelRequest(pick: .file)], "an unfiltered file pick")
		#expect(!h.stub.calls.contains("createVM"), "Cancel created a VM: \(h.stub.calls)")

		let ipsw = URL(fileURLWithPath: "/Users/demo/Downloads/UniversalMac_26.0_Restore.ipsw")
		AddFlows.newMacFromFile(viewModel: h.viewModel, panels: Self.answering(ipsw))
		#expect(await eventually { h.stub.calls.contains("startMacInstall") }, "\(h.stub.calls)")
		#expect(h.stub.calls.filter { $0 == "createVM" }.count == 1)
	}
}
