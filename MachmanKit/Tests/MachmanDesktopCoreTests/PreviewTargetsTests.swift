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

	// RR3-1: the selected VM starts; the daemon announces the run with a running stateChanged,
	// and its preview polls from then on, focus unchanged.
	@Test func aStartedSelectedVMPolls() async {
		let h = await DesktopHarness.make()
		let subscribed = h.stub.calls.filter { $0 == "events" }.count
		let previews = previews(h)
		#expect(previews.pollingNames.isEmpty)
		// The service subscribes from a task; an event before that would reach nobody.
		#expect(await eventually(timeout: .seconds(5)) {
			h.stub.calls.filter { $0 == "events" }.count > subscribed
		})
		h.stub.emit(.stateChanged(vm: "Alpine", state: .running))
		#expect(await eventually(timeout: .seconds(5)) { previews.pollingNames == ["Alpine"] })
		previews.detach()
	}

	// A reload alone can show the selected VM running (a vmhost adopted late, the list after
	// a reconnect): its preview polls then too, with no stateChanged of its own.
	@Test func aReloadThatShowsTheSelectedVMRunningPolls() async {
		let h = await DesktopHarness.make()
		let previews = previews(h)
		h.stub.vms["Alpine"]?.state = .running
		await h.store.reload()
		#expect(await eventually(timeout: .seconds(5)) { previews.pollingNames == ["Alpine"] })
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

	// MARK: - Frames of VMs that left (P40)

	// Debian runs and is shown: its first poll lands a frame.
	private func debianWithAFrame(_ h: DesktopHarness) async -> PreviewService {
		h.stub.previewPayload = Samples.previewPNG()
		let previews = previews(h)
		previews.setVisible(["Debian"])
		#expect(await eventually { previews.images.images["Debian"] != nil })
		previews.setVisible([])
		return previews
	}

	// A deleted VM's last frame stayed under its name for the app's lifetime, and the next VM
	// of that name (the macOS template's default name makes it likely) showed it.
	@Test("P40: a VM recreated under a deleted VM's name shows no old frame")
	func aReusedNameShowsNoOldFrame() async throws {
		let h = await DesktopHarness.make()
		let previews = await debianWithAFrame(h)
		try await h.stub.deleteVM(named: "Debian")
		#expect(await eventually { !h.store.vms.contains { $0.name == "Debian" } })
		h.stub.vms["Debian"] = Samples.linux("Debian")
		h.stub.emit(.listChanged)
		#expect(await eventually { h.store.vms.contains { $0.name == "Debian" } })
		#expect(await eventually { previews.images.images["Debian"] == nil })
		previews.detach()
	}

	// The rename's reply moves the frame before the list that carries the new name lands; a
	// list in between (any VM's state change) must not prune it.
	@Test("P40: a renamed VM keeps its frame while the list catches up")
	func aRenamedVMKeepsItsFrame() async throws {
		let h = await DesktopHarness.make()
		let previews = await debianWithAFrame(h)
		previews.renameVM(from: "Debian", to: "Debian 2")
		h.stub.emit(.stateChanged(vm: "Alpine", state: .running))
		#expect(await eventually { h.store.vms.first { $0.name == "Alpine" }?.state == .running })
		try await Task.sleep(for: .milliseconds(50))   // the prune runs a turn after the list
		#expect(previews.images.images["Debian 2"] != nil)
		try await h.stub.renameVM(named: "Debian", to: "Debian 2")
		#expect(await eventually { h.store.vms.contains { $0.name == "Debian 2" } })
		try await Task.sleep(for: .milliseconds(50))
		#expect(previews.images.images["Debian 2"] != nil)
		previews.detach()
	}
}
