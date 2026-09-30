import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Dropped/pasted files: disk files queue the copy-or-reference question, folders mount.
@MainActor
struct AddFlowTests {
	@Test func aDiskFileQueuesTheQuestionAndReferenceAddsIt() async throws {
		let h = await DesktopHarness.make()
		let file = TestEnvironment.scratchURL.appendingPathComponent("\(UUID()).iso")
		try Data([0]).write(to: file)
		#expect(AddFlows.handleFileURLs([file], viewModel: h.viewModel, vm: "Debian"))
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.url == file)
		AddFlows.addDiskReference(viewModel: h.viewModel, vm: pending.vm, url: pending.url)
		#expect(await eventually { h.stub.addedDisks.count == 1 })
		#expect(h.stub.addedDisks.first?.disk == .iso(path: file.path))
	}

	@Test func aFolderBecomesAMount() async throws {
		let h = await DesktopHarness.make()
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		#expect(AddFlows.handleFileURLs([dir], viewModel: h.viewModel, vm: "Debian"))
		#expect(await eventually { h.stub.calls.contains("addMount") })
		#expect(h.viewModel.pendingDiskAdd == nil)
	}
}
