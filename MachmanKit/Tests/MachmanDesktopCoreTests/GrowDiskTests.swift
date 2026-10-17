//
//  GrowDiskTests.swift
//  MachmanDesktopCoreTests
//
//  F5: growing a disk was the one mutation that succeeded silently — rename, add and remove
//  all confirm with a toast. H3: the grow control was an 8 GB-step stepper; it is a typed
//  target size now (bare number = GB, decimals fine), refused with a reason when it can't be.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct GrowDiskTests {
	@Test func aGrowEndsInAToast() async {
		let h = await DesktopHarness.make()
		h.viewModel.resizeDisk("Alpine", diskID: "storage:system", sizeBytes: 64 << 30)
		#expect(await eventually {
			h.viewModel.toasts.contains { $0.message == "Disk grown to 64 GB" }
		})
		#expect(h.stub.vms["Alpine"]?.disks.first?.sizeBytes == 64 << 30)
	}

	@Test func aRefusedGrowAlertsWithoutAToast() async {
		let h = await DesktopHarness.make()
		h.stub.fail(
			"resizeDisk", with: MachmanError(code: .invalidState, message: "Stop Alpine first"))
		h.viewModel.resizeDisk("Alpine", diskID: "storage:system", sizeBytes: 64 << 30)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.presentedError?.title == "Growing a disk failed")
		#expect(!h.viewModel.toasts.contains { $0.message.hasPrefix("Disk grown") })
	}

	private func harness(_ vms: [VMInfo] = Samples.library()) async -> DesktopHarness {
		let h = await DesktopHarness.make(vms)
		_ = await eventually { h.viewModel.capabilities != nil }
		return h
	}

	@Test func growProblemsAreExplained() async throws {
		let h = await harness()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		let system = try #require(alpine.disks.first { $0.id == "storage:system" })
		let problem = { (text: String) in h.viewModel.growDiskProblem(text, disk: system) }
		#expect(problem("") == nil)
		#expect(problem("  ") == nil)
		#expect(problem("lots") == "Enter a size like 64 or 1.5 GB")
		#expect(problem("16") == "Disks only grow \u{2014} enter more than 32 GB")
		#expect(problem("32") == "Disks only grow \u{2014} enter more than 32 GB")
		#expect(problem("500") == "Only 412 GB is free")
		#expect(problem("64") == nil)
		#expect(problem("40.5") == nil)
		#expect(problem("40960m") == nil)
		#expect(problem("0.25 TB") == nil)   // R3-2: TB, as display writes it
		#expect(problem("1t") == "Only 412 GB is free")
	}

	@Test func aTypedSizeIsSentExactly() async throws {
		let h = await harness()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		#expect(h.viewModel.submitGrowDisk(alpine, diskID: "storage:system", text: "40.5"))
		#expect(await eventually {
			h.stub.vms["Alpine"]?.disks.first?.sizeBytes == (40 << 30) + (512 << 20)
		})
		#expect(h.viewModel.submitGrowDisk(alpine, diskID: "storage:system", text: "64"))
		#expect(await eventually { h.stub.vms["Alpine"]?.disks.first?.sizeBytes == 64 << 30 })
	}

	@Test func nothingIsSentWhileTheVMCantGrowIt() async throws {
		let h = await harness()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		let iso = try #require(alpine.disks.first { $0.type == .iso })
		#expect(!h.viewModel.submitGrowDisk(debian, diskID: "storage:system", text: "64"))
		#expect(!h.viewModel.submitGrowDisk(alpine, diskID: iso.id, text: "64"))
		#expect(!h.viewModel.submitGrowDisk(alpine, diskID: "storage:system", text: "16"))
		#expect(!h.viewModel.submitGrowDisk(alpine, diskID: "storage:system", text: ""))
		let stalled = await harness([Samples.neverAnswered()])
		let unanswered = try #require(stalled.viewModel.vms.first)
		#expect(!stalled.viewModel.submitGrowDisk(
			unanswered, diskID: "storage:system", text: "64"))
		#expect(await h.settled())
		#expect(await stalled.settled())
		#expect(!h.stub.calls.contains("resizeDisk"))
		#expect(!stalled.stub.calls.contains("resizeDisk"))
	}
}
