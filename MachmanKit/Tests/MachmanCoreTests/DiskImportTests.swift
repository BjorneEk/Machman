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
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct DiskImportTests {
	private func makeDir() throws -> String {
		let dir = TestEnvironment.scratch + "diskimport-\(UUID().uuidString)"
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

	// D23: attributesOfItem is lstat, so a raw image passed as a symlink measured as the link
	// itself (a hundred-odd bytes) and was refused as misaligned; a fromUrl disk that is a
	// link showed the link's length, and a copy's progress total took it too.
	@Test func aRawImageReachedThroughALinkMeasuresAsTheImage() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let fm = FileManager.default
		let vmDir = dir + "/vm"
		try fm.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		try fm.createDirectory(atPath: dir + "/images", withIntermediateDirectories: true)
		let image = dir + "/images/cloud.img"
		let bytes = Data(repeating: 0xCD, count: 4096)
		try bytes.write(to: URL(fileURLWithPath: image))
		let link = dir + "/cloud-link.img"
		try fm.createSymbolicLink(atPath: link, withDestinationPath: image)

		let disk = try DiskImport.importFile(src: link, vmDir: vmDir, takenStorageNames: [])
		guard case .storage(let name, let size) = disk.kind else {
			Issue.record("expected a storage entry")
			return
		}
		#expect(size == 4096)
		#expect(try Data(contentsOf: URL(fileURLWithPath: vmDir + "/\(name).raw")) == bytes)

		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		#expect(config.getDiskSize(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: link))))
			== 4096)

		final class Totals: @unchecked Sendable {
			let lock = NSLock()
			var values: [UInt64] = []
			func add(_ total: UInt64) {
				lock.lock()
				values.append(total)
				lock.unlock()
			}
		}
		let totals = Totals()
		try FileTransfer.copy(
			src: link, dst: dir + "/copy.raw", progress: { totals.add($1) }, allowClone: false)
		#expect(!totals.values.isEmpty)
		#expect(totals.values.allSatisfy { $0 == 4096 })
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
				src: src, vmDir: vmDir, name: { "big.raw" },
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

	// D18: the name is derived when the copy lands. Another import of a same-named file (or
	// a new disk) that took it meanwhile no longer fails this one after the whole copy — it
	// re-derives past it, and the file that won keeps its bytes.
	@Test func aNameTakenDuringTheCopyIsDerivedAgain() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let vmDir = dir + "/vm"
		try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
		let src = dir + "/data.img"
		try Data(repeating: 0xCD, count: 1024).write(to: URL(fileURLWithPath: src))
		try writeISO(at: dir + "/boot.iso")
		let landsFirst: (String) -> (String, String) throws -> Void = { winner in
			{ from, staging in
				try Data("winner".utf8).write(to: URL(fileURLWithPath: vmDir + "/" + winner))
				try FileManager.default.copyItem(atPath: from, toPath: staging)
			}
		}

		let raw = try DiskImport.importFile(
			src: src, vmDir: vmDir, takenStorageNames: [], transfer: landsFirst("data.raw"))
		guard case .storage(let name, _) = raw.kind else {
			Issue.record("expected a storage entry")
			return
		}
		#expect(name == "data-2")
		#expect(try Data(contentsOf: URL(fileURLWithPath: vmDir + "/data-2.raw"))
			== Data(repeating: 0xCD, count: 1024))
		#expect(try Data(contentsOf: URL(fileURLWithPath: vmDir + "/data.raw"))
			== Data("winner".utf8))

		let iso = try DiskImport.importFile(
			src: dir + "/boot.iso", vmDir: vmDir, takenStorageNames: [],
			transfer: landsFirst("boot.iso"))
		guard case .iso(let url) = iso.kind else {
			Issue.record("expected an iso entry")
			return
		}
		#expect(url.path == vmDir + "/boot-2.iso")
		#expect(try Data(contentsOf: URL(fileURLWithPath: vmDir + "/boot.iso"))
			== Data("winner".utf8))
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: vmDir)
			.filter { $0.hasPrefix(DiskImport.stagingPrefix) }
		#expect(leftovers.isEmpty)
	}

	// The exclusive placement itself: a taken name is reported, never replaced.
	@Test func placementNeverReplaces() throws {
		let dir = try makeDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		try Data("staged".utf8).write(to: URL(fileURLWithPath: dir + "/staged"))
		try Data("taken".utf8).write(to: URL(fileURLWithPath: dir + "/taken"))
		#expect(try !DiskImport.placeExclusively(dir + "/staged", at: dir + "/taken"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/taken")) == Data("taken".utf8))
		#expect(try DiskImport.placeExclusively(dir + "/staged", at: dir + "/free"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/free")) == Data("staged".utf8))
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
			var external = VMDisk(
				kind: .fromUrl(URL(fileURLWithPath: "/imgs/a.img")), safe: false)
			external.enabled = false
			let ownedIso = VMDisk(kind: .iso(URL(fileURLWithPath: vmDir + "/boot.iso")))
			let externalIso = VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/ext.iso")))
			cfg.disks = [VMDisk(kind: .storage("data", 0)), external, ownedIso, externalIso]
			try cfg.saveVMConfig()
			try Data("iso".utf8).write(to: URL(fileURLWithPath: vmDir + "/boot.iso"))

			// Promote-style swap: position 1 keeps its slot and both flags (C19: a promote
			// once enabled a disabled disk).
			try cfg.replaceDisk(id: external.id, kind: .storage("a", 512))
			let reloaded = try VMConfig.load(name: "alpha")
			guard case .storage(let name, _) = reloaded.disks[1].kind else {
				Issue.record("expected the swap in place")
				return
			}
			#expect(name == "a")
			#expect(reloaded.disks[1].safe == false)
			#expect(reloaded.disks[1].enabled == false)

			// Residency-aware delete: the in-dir iso file dies with its entry…
			try cfg.deleteDisk(disk: ownedIso)
			#expect(!FileManager.default.fileExists(atPath: vmDir + "/boot.iso"))
			// …while unknown ids still refuse the swap.
			#expect(throws: MachmanError.self) {
				try cfg.replaceDisk(id: "bogus", kind: external.kind)
			}
		}
	}
}
