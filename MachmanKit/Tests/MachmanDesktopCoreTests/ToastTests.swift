import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// The toast corner stays readable: repeated warnings collapse, the stack is capped (P15).
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
			symbol: MachmanSymbols.deviceSSHSetup, message: "SSH: connecting to Debian…",
			key: VMListViewModel.sshWaitToastKey("Debian"), spinner: true, sticky: true)
		for n in 1...6 {
			h.viewModel.pushToast(symbol: MachmanSymbols.warning, message: "w\(n)")
		}
		#expect(h.viewModel.toasts.count == VMListViewModel.maxToasts)
		#expect(h.viewModel.toasts.first?.message == "SSH: connecting to Debian…")
		#expect(h.viewModel.toasts.last?.message == "w6")
	}
}
