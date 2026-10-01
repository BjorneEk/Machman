import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// A VM whose vmhost stopped answering stays in the list as its last known state, marked
// unresponsive (decision 10): the rest of the list keeps working, and neither the stall nor
// the recovery reads as a start or a stop.
@MainActor
struct NotRespondingTests {
	@Test func aStalledHostKeepsItsRowWhileTheListUpdates() async {
		let h = await DesktopHarness.make(Samples.libraryWithStalledHost())
		let selected = h.viewModel.selectedName
		#expect(h.viewModel.vms.count == 5)
		#expect(h.viewModel.vms.first { $0.name == "Debian" }?.isUnresponsive == true)

		h.stub.vms["Debian"]?.unresponsive = nil
		h.stub.emit(.listChanged)
		#expect(await eventually {
			h.viewModel.vms.first { $0.name == "Debian" }?.isUnresponsive == false
		})
		#expect(h.viewModel.vms.count == 5)
		#expect(h.viewModel.selectedName == selected)
		#expect(h.viewModel.toasts.isEmpty)
	}

	// A vmhost adopted late lists as unknown until then, and was running all along: its
	// adoption is no "started" moment.
	@Test func anAdoptedVMIsNoStart() async {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .unknown)])
		h.stub.vms["Debian"]?.state = .running
		h.stub.emit(.listChanged)
		#expect(await eventually { h.viewModel.vms.first?.state == .running })
		#expect(h.viewModel.toasts.isEmpty)
	}
}
