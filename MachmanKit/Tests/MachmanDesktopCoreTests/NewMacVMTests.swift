import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// H21 (decision 15): the New VM picker's macOS template opens straight into the Install macOS
// flow. Once a source is picked the VM is created from the mac template, selected, and its
// install starts with that source; nothing is created before. It used to create an EFI VM
// whose Install macOS… only Bootloader ▸ macOS… reached.
@MainActor
struct NewMacVMTests {
	@Test func theMacTemplateGoesStraightIntoTheInstall() async throws {
		let h = await DesktopHarness.make()
		let count = h.stub.vms.count
		await h.viewModel.createMacVM(source: .latest)
		let name = "new-VM\(count + 1)"
		#expect(h.stub.lastCreateTemplate == .mac)
		#expect(await eventually { h.stub.installs.count == 1 })
		#expect(h.stub.installs.first?.vm == name)
		#expect(h.stub.installs.first?.source == .latest)
		#expect(h.viewModel.selectedName == name)
	}

	@Test func anIPSWSourceTravels() async throws {
		let h = await DesktopHarness.make()
		await h.viewModel.createMacVM(source: .ipsw("/x/UniversalMac.ipsw"))
		#expect(await eventually { h.stub.installs.count == 1 })
		#expect(h.stub.installs.first?.source == .ipsw("/x/UniversalMac.ipsw"))
	}

	@Test func aFailedCreateInstallsNothing() async throws {
		let h = await DesktopHarness.make()
		let before = h.viewModel.selectedName
		h.stub.fail("createVM", with: MachmanError(code: .internalError, message: "disk full"))
		await h.viewModel.createMacVM(source: .latest)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.stub.installs.isEmpty)
		#expect(!h.stub.calls.contains("startMacInstall"))
		#expect(h.viewModel.selectedName == before)
	}
}
