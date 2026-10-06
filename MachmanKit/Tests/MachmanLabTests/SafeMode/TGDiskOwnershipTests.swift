//
//  TGDiskOwnershipTests.swift
//  MachmanLabTests
//
//  L2 — disk ownership on the lab agent, no guest booted: an import copies an image into
//  the VM's folder as its own, a reference stays the user's file and can be promoted in
//  place, the format sniff and the size rule refuse what the VM can't use, and a duplicate
//  takes its own copy of an owned ISO.
//

import Foundation
import Testing
import MachmanAPI

@Suite("Disk ownership", .serialized, .enabled(if: Lab.runs(.l2)))
struct TGDiskOwnershipTests {
	static let qcowRefusal = "Machman can\u{2019}t use qcow2 images \u{2014} convert to raw first "
		+ "(qemu-img convert -O raw)"

	/// Card D29, a qcow2 attached by reference (r3-tg, D/RISK).
	static let qcowByReferenceCard = Comment(rawValue: "D29: A disk added by reference skips the "
		+ "format sniff: a qcow2 attaches as raw bytes")

	/// A file whose first bytes are qcow2's magic ("QFI\u{FB}"), 64 KiB in all.
	static func writeQcow(_ path: String) throws {
		var bytes = Data([0x51, 0x46, 0x49, 0xFB, 0x00, 0x00, 0x00, 0x03])
		bytes.append(Data(repeating: 0x11, count: (64 << 10) - bytes.count))
		try bytes.write(to: URL(fileURLWithPath: path))
	}

	static func listing(_ dir: String) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
	}

	@Test("17a: a raw image imports as an owned copy or attaches as a promotable reference")
	func rawImportAndReference() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("raw-import", on: agent)
			let source = agent.scope.imagesDir + "/src.img"
			try await TG.writeFile(source, size: 4 << 20, fill: 0x5A)
			let sum = try await TG.sha256(source)
			let before = try await vm.info().disks
			let imported = try await agent.api.importDisk(vm: vm.name, path: source)
			let copy = try #require(imported.disks.first { !before.contains($0) })
			#expect(copy.type == .storage)
			#expect(copy.owned == true)
			let copyPath = try #require(copy.path)
			#expect(copyPath.hasPrefix(vm.dir + "/"))
			#expect(try await TG.sha256(copyPath) == sum)
			#expect(try await TG.sha256(source) == sum)
			// An owned disk has nothing to promote.
			let promote = await #expect(throws: MachmanError.self) {
				_ = try await agent.api.promoteDisk(vm: vm.name, diskID: copy.id)
			}
			#expect(promote?.code == .invalidState)
			#expect(promote?.message == "This disk is already owned by the VM")
			// By reference: the user's own file, promotable.
			try await agent.api.addDisk(vm: vm.name, .image(path: source))
			let reference = try await vm.disk(path: source)
			#expect(reference.type == .image)
			#expect(reference.owned == false)
			#expect(try await TG.sha256(source) == sum)
		}
	}

	@Test("17a: a qcow2 import is refused with the convert sentence")
	func qcowImportRefused() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("qcow2-import", on: agent)
			let qcow = agent.scope.imagesDir + "/disk.qcow2"
			try Self.writeQcow(qcow)
			let files = Self.listing(vm.dir)
			let disks = try await vm.info().disks
			let refused = await #expect(throws: MachmanError.self) {
				_ = try await agent.api.importDisk(vm: vm.name, path: qcow)
			}
			#expect(refused?.code == .invalidArgument)
			#expect(refused?.message == Self.qcowRefusal)
			// Nothing staged or left behind, no entry added.
			#expect(Self.listing(vm.dir) == files)
			#expect(try await vm.info().disks == disks)
		}
	}

	@Test("17a: a qcow2 added by reference is refused with the convert sentence")
	func qcowReferenceRefused() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("qcow2-reference", on: agent)
			let qcow = agent.scope.imagesDir + "/ref.qcow2"
			try Self.writeQcow(qcow)
			var refusal: MachmanError?
			do {
				try await agent.api.addDisk(vm: vm.name, .image(path: qcow))
			} catch let error as MachmanError {
				refusal = error
			}
			let attached = try await vm.info().disks.contains { $0.path == qcow }
			withKnownIssue(Self.qcowByReferenceCard) {
				#expect(refusal?.message == Self.qcowRefusal)
				#expect(!attached)
			}
		}
	}

	@Test("20a: an unaligned .txt is refused and an aligned .raw imports as an owned disk")
	func textRefusedRawImported() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("unaligned", on: agent)
			let notes = agent.scope.imagesDir + "/notes.txt"
			try Data("lab notes\n".utf8).write(to: URL(fileURLWithPath: notes))
			let files = Self.listing(vm.dir)
			let refused = await #expect(throws: MachmanError.self) {
				_ = try await agent.api.importDisk(vm: vm.name, path: notes)
			}
			#expect(refused?.code == .invalidArgument)
			#expect(refused?.message
				== "Raw disk images must be a non-empty multiple of 512 bytes, and notes.txt "
					+ "is 10 bytes")
			#expect(Self.listing(vm.dir) == files)
			let raw = agent.scope.imagesDir + "/disk.raw"
			try await TG.writeFile(raw, size: 1 << 20)
			let imported = try await agent.api.importDisk(vm: vm.name, path: raw)
			let disk = try #require(imported.disks.first { $0.name == "disk" })
			#expect(disk.type == .storage)
			#expect(disk.owned == true)
			#expect(disk.path == vm.dir + "/disk.raw")
		}
	}

	@Test("18: an imported ISO lands in the VM folder, and Duplicate points the copy at its own")
	func isoImportFollowsDuplicate() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("iso-import", on: agent)
			let source = agent.scope.imagesDir + "/tg.iso"
			var iso = Data(repeating: 0x20, count: 64 << 10)
			iso.replaceSubrange(0x8001..<0x8006, with: Data("CD001".utf8))
			try iso.write(to: URL(fileURLWithPath: source))
			let imported = try await agent.api.importDisk(vm: vm.name, path: source)
			let owned = vm.dir + "/tg.iso"
			let entry = try #require(imported.disks.first { $0.type == .iso })
			#expect(entry.path == owned)
			#expect(entry.owned == true)
			#expect(FileManager.default.fileExists(atPath: owned))
			// Duplicate: the copy's ISO entry points into the copy's own folder.
			let copy = try await agent.api.copyVM(
				vm: vm.name, newName: "iso-copy", diskIDs: nil, regenerateMAC: true)
			let copied = TG.vmDir(agent.scope, "iso-copy") + "/tg.iso"
			let copyEntry = try #require(copy.disks.first { $0.type == .iso })
			#expect(copyEntry.path == copied)
			#expect(FileManager.default.fileExists(atPath: copied))
			#expect(try await TG.sha256(copied) == (try await TG.sha256(owned)))
			// The original's entry and file stay as they were.
			let original = try #require(try await vm.info().disks.first { $0.type == .iso })
			#expect(original.path == owned)
			#expect(FileManager.default.fileExists(atPath: owned))
		}
	}

	@Test("19: promoting an external image keeps its row and safe flag and leaves the source")
	func promoteKeepsRowAndFlag() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.blank("promoted", on: agent)
			let external = agent.scope.imagesDir + "/ext.img"
			try await TG.writeFile(external, size: 2 << 20, fill: 0x3C)
			let sum = try await TG.sha256(external)
			let first = try await vm.info().disks.count
			try await agent.api.addDisk(vm: vm.name, .storage(name: "a", sizeBytes: 1 << 20))
			try await agent.api.addDisk(vm: vm.name, .image(path: external))
			try await agent.api.addDisk(vm: vm.name, .storage(name: "b", sizeBytes: 3 << 20))
			let ext = try await vm.disk(path: external)
			try await agent.api.setSafety(vm: vm.name, disks: [ext.id: false], mounts: nil)
			let before = try await vm.info().disks
			try #require(before.count == first + 3)
			#expect(before[first + 1].id == ext.id)
			#expect(before[first + 1].safe == false)
			let promoted = try await agent.api.promoteDisk(vm: vm.name, diskID: ext.id).disks
			try #require(promoted.count == before.count)
			// Same row, now owned storage in the VM's folder, still unsafe.
			let row = promoted[first + 1]
			#expect(row.type == .storage)
			#expect(row.owned == true)
			#expect(row.safe == false)
			#expect(row.path?.hasPrefix(vm.dir + "/") == true)
			#expect(promoted[first] == before[first])
			#expect(promoted[first + 2] == before[first + 2])
			// The source is untouched, and the promoted row has nothing left to promote.
			#expect(try await TG.sha256(external) == sum)
			let again = await #expect(throws: MachmanError.self) {
				_ = try await agent.api.promoteDisk(vm: vm.name, diskID: row.id)
			}
			#expect(again?.message == "This disk is already owned by the VM")
		}
	}
}
