//
//  VMKeyedStateTests.swift
//  MachmanDesktopCoreTests
//
//  PR24 (T29): client state keyed by a VM's name lived in six stores, and each of rename,
//  Save as New VM and deletion reached a different subset of them — port profiles never
//  followed a safe save nor went with a deleted VM. Every store is a VMKeyedState now, and
//  the view model walks them all, in one place, for each of the three.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// A store that records what reached it.
@MainActor
private final class RecordingState: VMKeyedState {
	var moves: [String] = []
	var kept: [Set<String>] = []

	func renameVM(from old: String, to new: String) { moves.append("rename \(old) → \(new)") }
	func copyVM(from old: String, to new: String) { moves.append("copy \(old) → \(new)") }
	func forgetVMs(except kept: Set<String>) { self.kept.append(kept) }
}

// L1: view model on StubMachman.
@MainActor
struct VMKeyedStateTests {
	@Test("T29: a rename, a safe save and a deletion reach every VM-keyed store")
	func everyNameChangeReachesEveryStore() async throws {
		let h = await DesktopHarness.make([
			Samples.linuxSafeRun("Debian"), Samples.linux("Alpine"), Samples.linux("Fedora"),
		])
		h.stub.safeSaveKeepsOriginal = true
		let own: [any VMKeyedState] = [
			h.terminals, h.canvases, h.previews, h.operations, h.viewModel.announcerMemory,
		]
		for store in own {
			#expect(h.viewModel.keyedState.contains { $0 === store }, "\(type(of: store))")
		}
		let recorder = RecordingState()
		h.viewModel.keyedState.append(recorder)

		#expect(await h.viewModel.rename(from: "Alpine", to: "Alpine 2"))
		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(await eventually { h.viewModel.hasVM("Debian kept") })
		try await h.stub.deleteVM(named: "Fedora")
		#expect(await eventually {
			!h.viewModel.hasVM("Fedora") && recorder.kept.last?.contains("Fedora") == false
		})
		#expect(recorder.moves == ["rename Alpine → Alpine 2", "copy Debian → Debian kept"])
		#expect(recorder.kept.last?.isSuperset(of: ["Alpine 2", "Debian", "Debian kept"]) == true)
	}
}
