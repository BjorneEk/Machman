import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// The toast corner stays readable: repeated warnings collapse, the stack is capped (P15); a
// settings file set aside at launch is announced once (P19).
@MainActor
struct ToastTests {
	@Test func aRepeatedWarningKeepsOneToast() async {
		let h = await DesktopHarness.make()
		for _ in 0..<3 {
			h.stub.emit(.log(vm: "Debian", level: .warning, message: "uart dropped"))
		}
		h.stub.emit(.log(vm: nil, level: .warning, message: "sentinel"))
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == "sentinel" } })
		let repeated = h.viewModel.toasts.filter { $0.message == "Debian: uart dropped" }
		#expect(repeated.count == 1)
	}

	@Test func aBurstKeepsTheNewestFive() async {
		let h = await DesktopHarness.make()
		for n in 1...8 {
			h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "w\(n)")
		}
		#expect(h.viewModel.toasts.count == VMListViewModel.maxToasts)
		#expect(h.viewModel.toasts.map(\.message) == ["w4", "w5", "w6", "w7", "w8"])
	}

	@Test func stickyWaitsSurviveTheCap() async {
		let h = await DesktopHarness.make()
		h.viewModel.pushToast(
			symbol: MachmanSymbols.deviceSSHSetup, message: "Debian: SSH connecting…",
			key: VMListViewModel.sshWaitToastKey("Debian"), spinner: true, sticky: true)
		for n in 1...6 {
			h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "w\(n)")
		}
		#expect(h.viewModel.toasts.count == VMListViewModel.maxToasts)
		#expect(h.viewModel.toasts.first?.message == "Debian: SSH connecting…")
		#expect(h.viewModel.toasts.last?.message == "w6")
	}

	// F6: a toast the pointer rests on outlives its timer, then lives a fresh lifetime.
	@Test func aHoveredToastStays() async {
		let h = await DesktopHarness.make()
		h.viewModel.toastLifetimeOverride = .milliseconds(200)
		h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "long warning")
		let id = h.viewModel.toasts.first { $0.message == "long warning" }!.id
		h.viewModel.holdToast(id, true)
		try? await Task.sleep(for: .seconds(2))
		#expect(h.viewModel.toasts.contains { $0.id == id })
		h.viewModel.holdToast(id, false)
		#expect(await eventually { !h.viewModel.toasts.contains { $0.id == id } })
	}

	// A keyed slot replaced under the pointer keeps the hold (the slot is what is hovered).
	@Test func aReplacedToastKeepsTheHold() async {
		let h = await DesktopHarness.make()
		h.viewModel.toastLifetimeOverride = .milliseconds(200)
		h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "first", key: "slot")
		h.viewModel.holdToast(h.viewModel.toasts.first { $0.key == "slot" }!.id, true)
		h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "second", key: "slot")
		try? await Task.sleep(for: .seconds(2))
		#expect(h.viewModel.toasts.map(\.message) == ["second"])
	}

	// A settings file set aside at launch is announced once, naming its backup (P19).
	@Test func anUnreadableSettingsFileIsAnnouncedOnce() async throws {
		let h = await DesktopHarness.make()
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent("TerminalProfiles.json")
		try Data("not json".utf8).write(to: url)
		let profiles = TerminalProfileStore(fileURL: url)
		h.viewModel.announceSetAsideSettings([profiles, h.canvases])
		#expect(h.viewModel.toasts.map(\.message) == [
			"Couldn’t read your terminal profiles — the old file is kept as "
				+ "TerminalProfiles.json.bak",
		])
		h.viewModel.announceSetAsideSettings([profiles, h.canvases])   // as after a reconnect
		#expect(h.viewModel.toasts.count == 1)
	}
}
