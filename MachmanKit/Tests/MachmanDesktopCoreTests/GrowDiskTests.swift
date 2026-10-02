//
//  GrowDiskTests.swift
//  MachmanDesktopCoreTests
//
//  F5: growing a disk was the one mutation that succeeded silently — rename, add and remove
//  all confirm with a toast.
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
}
