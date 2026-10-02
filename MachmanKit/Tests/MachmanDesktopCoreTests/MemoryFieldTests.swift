//
//  MemoryFieldTests.swift
//  MachmanDesktopCoreTests
//
//  H4: the memory field read a bare number as BYTES ("8" = 8 bytes) and clamped it to the
//  host minimum without a word. Decision 14: a bare number is GB, decimals and units are
//  fine, and a value outside the range lands on its edge with a note saying so.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MemoryFieldTests {
	private func harness() async -> DesktopHarness {
		let h = await DesktopHarness.make()
		_ = await eventually { h.viewModel.capabilities != nil }
		return h
	}

	@Test func aBareNumberIsGigabytes() async throws {
		let h = await harness()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		let entry = h.viewModel.submitMemory(alpine, text: "8")
		#expect(entry == MemoryEntry(bytes: 8 << 30, note: nil))
		#expect(await eventually { h.stub.vms["Alpine"]?.memoryBytes == 8 << 30 })
	}

	@Test func decimalsAndUnits() async {
		let h = await harness()
		#expect(h.viewModel.memoryEntry("1.5", floor: 0).bytes == 1536 << 20)
		#expect(h.viewModel.memoryEntry("2,5", floor: 0).bytes == 2560 << 20)
		#expect(h.viewModel.memoryEntry("512m", floor: 0).bytes == 512 << 20)
		#expect(h.viewModel.memoryEntry("8 GB", floor: 0).bytes == 8 << 30)
	}

	@Test func outOfRangeIsSaid() async throws {
		let h = await harness()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		let sequoia = try #require(h.viewModel.vms.first { $0.name == "Sequoia" })
		#expect(h.viewModel.submitMemory(alpine, text: "2048")
			== MemoryEntry(bytes: 24 << 30, note: "Lowered to this Mac's maximum"))
		#expect(await eventually { h.stub.vms["Alpine"]?.memoryBytes == 24 << 30 })
		#expect(h.viewModel.submitMemory(sequoia, text: "2")
			== MemoryEntry(bytes: 4 << 30, note: "Raised to this VM's minimum"))
		#expect(await eventually { h.stub.vms["Sequoia"]?.memoryBytes == 4 << 30 })
		#expect(h.viewModel.memoryEntry("100m", floor: 0)
			== MemoryEntry(bytes: 512 << 20, note: "Raised to this VM's minimum"))
	}

	@Test func unreadableSendsNothing() async throws {
		let h = await harness()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		#expect(h.viewModel.submitMemory(alpine, text: "g")
			== MemoryEntry(bytes: nil, note: "Enter a size like 8 or 1.5 GB"))
		// Alpine already has 4 GB: nothing to send.
		#expect(h.viewModel.submitMemory(alpine, text: "4")
			== MemoryEntry(bytes: 4 << 30, note: nil))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("setHardware"))
	}
}
