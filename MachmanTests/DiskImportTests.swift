//
//  DiskImportTests.swift
//  MachmanTests
//
//  The disk-ownership engine: magic sniffing, importFile's copy+derive on bare temp dirs
//  (no globals), and the VMConfig entry surgery (replaceDisk, residency-aware deleteDisk)
//  under the redirected dir.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct DiskImportTests {
	private func makeDir() throws -> String {
		let dir = NSTemporaryDirectory() + "diskimport-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	private func writeISO(at path: String) throws {
		var data = Data(count: 0x8001)
		data.append(Data("CD001".utf8))
		try data.write(to: URL(fileURLWithPath: path))
	}

	@Test func sniffRecognizesTheFormats() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }

		try Data([0x51, 0x46, 0x49, 0xFB, 0x00]).write(
			to: URL(fileURLWithPath: dir + "/q.qcow2"))
		#expect(DiskFormat.sniff(path: dir + "/q.qcow2") == .qcow)

		try writeISO(at: dir + "/d.iso")
		#expect(DiskFormat.sniff(path: dir + "/d.iso") == .iso)

		try Data(repeating: 0xAB, count: 512).write(to: URL(fileURLWithPath: dir + "/r.raw"))
		#expect(DiskFormat.sniff(path: dir + "/r.raw") == .raw)

		FileManager.default.createFile(atPath: dir + "/empty", contents: nil)
		#expect(DiskFormat.sniff(path: dir + "/empty") == .unreadable)
		#expect(DiskFormat.sniff(path: dir + "/missing") == .unreadable)
	}

	@Test func importRawCopiesDerivesAndExcludes() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		let src = dir + "/ubuntu-cloud.img"
		try Data(repeating: 0xCD, count: 1024).write(to: URL(fileURLWithPath: src))

		let disk = try DiskImport.importFile(
			src: src, vmDir: vmDir, takenStorageNames: [])
		guard case .storage(let name, let size) = disk.kind else {
			Issue.record("expected a storage entry")
			return
		}
		#expect(name == "ubuntu-cloud")
		#expect(size == 1024)
		#expect(try Data(contentsOf: URL(fileURLWithPath: vmDir + "/ubuntu-cloud.raw"))
			== Data(repeating: 0xCD, count: 1024))
		let values = try URL(fileURLWithPath: vmDir + "/ubuntu-cloud.raw")
			.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)

		// Name collisions dodge config storage names AND existing raws.
		let second = try DiskImport.importFile(
			src: src, vmDir: vmDir, takenStorageNames: ["data"])
		guard case .storage(let secondName, _) = second.kind else {
			Issue.record("expected a storage entry")
			return
		}
		#expect(secondName == "ubuntu-cloud-2")
	}

	@Test func importRefusesQcowAndMisalignedRaw() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)

		try Data([0x51, 0x46, 0x49, 0xFB]).write(to: URL(fileURLWithPath: dir + "/q.img"))
		#expect(throws: MachmanError.self) {
			try DiskImport.importFile(src: dir + "/q.img", vmDir: vmDir, takenStorageNames: [])
		}

		try Data(repeating: 0xAB, count: 100).write(to: URL(fileURLWithPath: dir + "/odd.raw"))
		#expect(throws: MachmanError.self) {
			try DiskImport.importFile(
				src: dir + "/odd.raw", vmDir: vmDir, takenStorageNames: [])
		}
		#expect(throws: MachmanError.self) {
			try DiskImport.importFile(src: dir + "/nope", vmDir: vmDir, takenStorageNames: [])
		}
	}

	@Test func importIsoLandsInDirAndUniquifies() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		try writeISO(at: dir + "/boot.iso")
		try Data("occupied".utf8).write(to: URL(fileURLWithPath: vmDir + "/boot.iso"))

		let disk = try DiskImport.importFile(
			src: dir + "/boot.iso", vmDir: vmDir, takenStorageNames: [])
		guard case .iso(let url) = disk.kind else {
			Issue.record("expected an iso entry")
			return
		}
		#expect(url.path == vmDir + "/boot-2.iso")
		#expect(FileManager.default.fileExists(atPath: vmDir + "/boot-2.iso"))
	}

	// D3: a copy that dies after writing bytes must not leave a partial file — not under
	// the final name, not under the staged one. The injected transfer simulates the
	// mid-copy failure a single APFS volume cannot produce (clonefile is atomic).
	@Test func failedCopyLeavesNoPartialFile() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		let src = dir + "/big.img"
		try Data(repeating: 0xEE, count: 1024).write(to: URL(fileURLWithPath: src))

		#expect(throws: MachmanError.self) {
			try DiskImport.stagedCopy(
				src: src, dst: vmDir + "/big.raw", vmDir: vmDir,
				transfer: { _, staging in
					try Data("partial".utf8).write(to: URL(fileURLWithPath: staging))
					throw MachmanError(code: .ioFailure, message: "disk full")
				})
		}
		#expect(try FileManager.default.contentsOfDirectory(atPath: vmDir).isEmpty)

		// The cancel path travels the same staging: nothing stays behind either.
		#expect(throws: MachmanError.self) {
			try DiskImport.importFile(
				src: src, vmDir: vmDir, takenStorageNames: [], isCancelled: { true })
		}
		#expect(try FileManager.default.contentsOfDirectory(atPath: vmDir).isEmpty)
	}

	// D3: crash leftovers (no in-process cleanup ran) are recognized by prefix and swept;
	// owned disk files are untouched.
	@Test func sweepRemovesOnlyStagedLeftovers() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		let staged = vmDir + "/" + DiskImport.stagingPrefix + "dead-import"
		try Data("partial".utf8).write(to: URL(fileURLWithPath: staged))
		try Data(repeating: 1, count: 512).write(to: URL(fileURLWithPath: vmDir + "/data.raw"))

		DiskImport.sweepStaleStaging(vmDir: vmDir)
		#expect(!FileManager.default.fileExists(atPath: staged))
		#expect(FileManager.default.fileExists(atPath: vmDir + "/data.raw"))
	}

	@Test @MainActor func replaceDiskSwapsInPlaceAndDeleteRespectsResidency() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			let vmDir = cfg.vmDirPath()
			let external = VMDisk(
				kind: .fromUrl(URL(fileURLWithPath: "/imgs/a.img")), safe: false)
			let ownedIso = VMDisk(kind: .iso(URL(fileURLWithPath: vmDir + "/boot.iso")))
			let externalIso = VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/ext.iso")))
			cfg.disks = [VMDisk(kind: .storage("data", 0)), external, ownedIso, externalIso]
			try cfg.saveVMConfig()
			try Data("iso".utf8).write(to: URL(fileURLWithPath: vmDir + "/boot.iso"))

			// Promote-style swap: position 1 keeps its slot, safe flag carried by caller.
			try cfg.replaceDisk(
				id: external.id, with: VMDisk(kind: .storage("a", 512), safe: false))
			let reloaded = try VMConfig.load(name: "alpha")
			guard case .storage(let name, _) = reloaded.disks[1].kind else {
				Issue.record("expected the swap in place")
				return
			}
			#expect(name == "a")
			#expect(reloaded.disks[1].safe == false)

			// Residency-aware delete: the in-dir iso file dies with its entry…
			try cfg.deleteDisk(disk: ownedIso)
			#expect(!FileManager.default.fileExists(atPath: vmDir + "/boot.iso"))
			// …while unknown ids still refuse the swap.
			#expect(throws: MachmanError.self) {
				try cfg.replaceDisk(id: "bogus", with: external)
			}
		}
	}
}
