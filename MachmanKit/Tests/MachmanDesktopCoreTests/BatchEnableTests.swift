import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// A13: Enable All / Disable All over a mixed tree selection is one vm.setEnabled — devices
// ride the same call as disks (1.0.12), so the batch is one config write, all or nothing.
// It used to send one vm.device.update per device beside the batch.
@MainActor
struct BatchEnableTests {
	@Test func aMixedSelectionIsOneEnableCall() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		let debian = try #require(h.store.vms.first { $0.name == "Debian" })
		let disk = try #require(debian.disks.first?.id)
		h.viewModel.treeSelection = [.disk(disk), .device(.network)]

		h.viewModel.setSelectionEnabled(false, vm: debian)

		#expect(await eventually { h.stub.calls.contains("setEnabled") })
		#expect(h.stub.calls.filter { $0 == "setEnabled" }.count == 1)
		#expect(!h.stub.calls.contains("updateDevice"))
		let after = try #require(h.stub.vms["Debian"])
		#expect(after.devices?.first { $0.kind == .network }?.enabled == false)
		#expect(after.disks.first { $0.id == disk }?.isEnabled == false)
	}
}
