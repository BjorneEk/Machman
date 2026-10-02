import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// E22 (decision 9): a VM still run by an older vmhost says "Restart this VM to finish
// updating" — the inspector's banner and the agent menu's row read the same sentence — and
// the lock lifts on the list that follows the VM's restart (the daemon drops the mark).
@MainActor
struct RestartToUpdateTests {
	@Test func theSentence() {
		#expect(Samples.outdatedHost().restartToUpdate == "Restart this VM to finish updating")
		#expect(Samples.linux("Debian", state: .running).restartToUpdate == nil)
	}

	@Test func theSelectedVMClearsAfterItsRestart() async throws {
		let h = await DesktopHarness.make(Samples.libraryWithOutdatedHost())
		h.viewModel.select(name: "Debian")
		#expect(await eventually { h.viewModel.selected?.restartToUpdate != nil })
		#expect(h.store.vms.first { $0.name == "Alpine" }?.restartToUpdate == nil)

		h.stub.vms["Debian"]?.outdatedHost = nil   // restarted under a current vmhost
		h.stub.emit(.listChanged)
		#expect(await eventually { h.viewModel.selected?.restartToUpdate == nil })
	}
}
