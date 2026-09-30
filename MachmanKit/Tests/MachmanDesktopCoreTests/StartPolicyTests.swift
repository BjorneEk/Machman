import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// A plain Start follows the VM's start policy (decision 7).
@MainActor
struct StartPolicyTests {
	@Test func plainStartFollowsAHeadlessPolicy() async {
		var vm = Samples.linux("Alpine")
		vm.startPolicy = StartPolicy(windowed: false, safe: false)
		let h = await DesktopHarness.make([vm])
		h.viewModel.startPolicyDriven(vm)
		#expect(await eventually { h.stub.starts.count == 1 })
		#expect(h.stub.starts.first?.options == StartOptions(openWindow: false, safe: false))
	}

	@Test func aMacConflictOffersTheForcedRetry() async {
		let vm = Samples.linux("Alpine")
		let h = await DesktopHarness.make([vm])
		h.stub.fail(
			"start", with: MachmanError(code: .macConflict, message: "MAC in use"))
		h.viewModel.startVM("Alpine")
		#expect(await eventually { h.viewModel.pendingForceStart?.name == "Alpine" })
		#expect(!h.viewModel.isStartPending("Alpine"))
	}
}
