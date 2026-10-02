//
//  NewDiskFormTests.swift
//  MachmanDesktopCoreTests
//
//  P25 and D15's desktop half: the New Disk form read "1.5" as 15 GB (it kept only the
//  digits — and disks only grow), accepted a name the VM already used, and disabled Create
//  without saying why.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct NewDiskFormTests {
	private func harness() async -> DesktopHarness {
		let h = await DesktopHarness.make()
		_ = await eventually { h.viewModel.capabilities != nil }
		return h
	}

	@Test func aDecimalSizeIsGigabytesNotDigits() async throws {
		let h = await harness()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.createDisk(on: debian, name: " data ", sizeText: "1.5"))
		#expect(await eventually { h.stub.addedDisks.count == 1 })
		#expect(h.stub.addedDisks.first?.disk == .storage(name: "data", sizeBytes: 1536 << 20))
		#expect(h.viewModel.createDisk(on: debian, name: "logs", sizeText: "2,5"))
		#expect(await eventually { h.stub.addedDisks.count == 2 })
		#expect(h.stub.addedDisks.last?.disk == .storage(name: "logs", sizeBytes: 2560 << 20))
	}

	@Test func aTakenNameIsRefusedWithAReason() async throws {
		let h = await harness()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.newDiskProblem(on: debian, name: "system", sizeText: "8")
			== "This VM already has a disk named \u{201C}system\u{201D}")
		#expect(!h.viewModel.createDisk(on: debian, name: "system", sizeText: "8"))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("addDisk"))
	}

	@Test func badSizesAndNamesAreExplained() async throws {
		let h = await harness()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		let problem = { (name: String, size: String) in
			h.viewModel.newDiskProblem(on: debian, name: name, sizeText: size)
		}
		#expect(problem("data", "lots") == "Enter a size like 64 or 1.5 GB")
		#expect(problem("data", "0") == "Enter a size like 64 or 1.5 GB")
		#expect(problem("data", "") == "Enter a size in GB")
		#expect(problem("data", "500") == "Only 412 GB is free")
		#expect(problem(".x", "8") == "A disk name can’t start with a dot")
		#expect(problem("a/b", "8") == "A disk name can’t contain \u{201C}/\u{201D}")
		#expect(problem("", "8") == "A disk name can’t be empty")
		#expect(problem("data", "64") == nil)
	}

	// H18: the free-space figure was truncated to whole GB, so 500 MB free read "0 GB".
	@Test func aSmallFreeSpaceIsNotZero() async throws {
		let h = await harness()
		h.stub.capabilities.freeDiskBytes = 500 << 20
		await h.store.refreshCapabilities()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.newDiskProblem(on: debian, name: "data", sizeText: "1")
			== "Only 500 MB is free")
	}
}
