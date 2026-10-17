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

	// The Run submenu's Start Headless used to send safe: false whatever the policy.
	@Test func explicitHeadlessKeepsAPolicysSafety() async {
		var vm = Samples.linux("Alpine")
		vm.startPolicy = StartPolicy(windowed: true, safe: true)
		let h = await DesktopHarness.make([vm])
		h.viewModel.startPolicyDriven(vm, .headless)
		#expect(await eventually { h.stub.starts.count == 1 })
		#expect(h.stub.starts.first?.options == StartOptions(openWindow: false, safe: true))
	}

	// Every affordance funnels into startPolicyDriven, so an install blocks them all.
	@Test func aStartDuringAnInstallIsNotSent() async throws {
		let h = await DesktopHarness.make()
		let sequoia = try #require(h.viewModel.vms.first { $0.name == "Sequoia" })
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: InstallPhase(kind: .installing)))
		#expect(await eventually { h.viewModel.isInstalling(sequoia) })
		#expect(!h.viewModel.canStart(sequoia))
		h.viewModel.startPolicyDriven(sequoia)
		#expect(!h.viewModel.isStartPending("Sequoia"))
		#expect(await h.settled())
		#expect(h.stub.starts.isEmpty)
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
