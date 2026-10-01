//
//  PreviewTargetsTests.swift
//  MachmanDesktopCoreTests
//
//  T18: a torn-off Configuration window of a running VM got no frames unless that VM was
//  also the main window's selection — it showed "Waiting for the first frame…" forever. The
//  previews now poll the selection plus every torn Configuration window, and only while
//  the app is focused.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct PreviewTargetsTests {
	// The library selects Alpine (stopped); Debian runs.
	private func previews(_ h: DesktopHarness) -> PreviewService {
		let previews = PreviewService(store: h.store, tornTabs: h.tornTabs)
		previews.attach(api: h.stub)
		previews.setVisible(["Alpine"])
		return previews
	}

	@Test func aTornConfigWindowPollsItsVM() async {
		let h = await DesktopHarness.make()
		let previews = previews(h)
		#expect(previews.pollingNames.isEmpty)
		let window = TornTab(vm: "Debian", tab: .config)
		h.tornTabs.open.insert(window)
		#expect(await eventually(timeout: .seconds(5)) { previews.pollingNames == ["Debian"] })
		#expect(await eventually(timeout: .seconds(5)) { h.stub.calls.contains("preview") })
		h.tornTabs.open.remove(window)
		#expect(await eventually(timeout: .seconds(5)) { previews.pollingNames.isEmpty })
		previews.detach()
	}

	@Test func aTornTerminalWindowDoesNotPoll() async {
		let h = await DesktopHarness.make()
		let previews = previews(h)
		h.tornTabs.open.insert(
			TornTab(vm: "Debian", tab: .terminal(SerialPortRef(kind: .console, index: 0))))
		try? await Task.sleep(for: .milliseconds(100))
		#expect(previews.pollingNames.isEmpty)
		previews.detach()
	}

	@Test func unfocusedStopsEveryLoop() async {
		let h = await DesktopHarness.make()
		let previews = previews(h)
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .config))
		#expect(await eventually(timeout: .seconds(5)) { previews.pollingNames == ["Debian"] })
		previews.setFocused(false)
		#expect(previews.pollingNames.isEmpty)
		previews.setFocused(true)
		#expect(previews.pollingNames == ["Debian"])
		previews.detach()
	}

	// The selection still counts on its own, and a VM both selected and torn polls once.
	@Test func theSelectionAndTornWindowsShareOneLoopPerVM() async {
		let h = await DesktopHarness.make()
		let previews = previews(h)
		previews.setVisible(["Debian"])
		#expect(previews.pollingNames == ["Debian"])
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .config))
		previews.setVisible(["Alpine"])
		#expect(previews.pollingNames == ["Debian"])
		previews.detach()
	}
}
