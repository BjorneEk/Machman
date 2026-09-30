import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Tree selection ↔ VM selection ↔ canvas tabs.
@MainActor
struct SelectionTests {
	@Test func launchSelectsTheFirstVM() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.selectedName == "Alpine")   // the stub lists by name
	}

	@Test func switchingVMsClearsTheTreeSelection() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		h.viewModel.select(name: "Sequoia")
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	@Test func closingATabDeselectsItsTreeRow() async {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		h.viewModel.select(name: "Debian")
		h.viewModel.treeSelection = [.serial(ref)]
		h.viewModel.tabClosed(.terminal(ref), vm: "Debian")
		#expect(h.viewModel.treeSelection.isEmpty)
	}
}
