//
//  DiskReferenceTests.swift
//  MachmanTests
//
//  C5's guards: a file in one VM's folder that another VM uses is never pulled out from
//  under it — no delete or rename of that folder, no removal or rename of that disk. The
//  shape is the one Save as New VM leaves: the saved VM ("kept") owns data.raw, and the
//  original ("alpha") attaches it by reference.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct DiskReferenceTests {
	// Inside the redirect: kept owns data.raw; alpha (and optionally more) reference it.
	@MainActor
	private func makePair(referencing path: String? = nil) throws -> VMRegistry {
		try VMConfig.createNewVMDirectory(name: "kept")
		let kept = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
		try kept.addNewStorageDisk(name: "data", size: 4096)
		try VMConfig.createNewVMDirectory(name: "alpha")
		let alpha = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
		let target = path ?? machmanVMDir + "/kept/data.raw"
		try alpha.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: target)), safe: false))
		return VMRegistry()
	}

	private var raw: String { machmanVMDir + "/kept/data.raw" }

	@Test @MainActor func deleteRefusesWhileAnotherVMUsesAFileInIt() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))
			let alpha = try #require(registry.vm(named: "alpha"))

			let error = try #require(throws: MachmanError.self) { try registry.delete(kept) }
			#expect(error.code == .invalidState)
			#expect(error.message.contains("alpha uses data.raw from kept's folder"))
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(registry.vm(named: "kept") === kept)

			// Removing alpha's reference only disconnects it; then kept goes.
			try registry.removeDisk(try #require(alpha.config.disks.first), from: alpha)
			#expect(FileManager.default.fileExists(atPath: raw))
			try registry.delete(kept)
			#expect(registry.vm(named: "kept") == nil)
		}
	}

	@Test @MainActor func renameRefusesLikewise() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))

			let error = try #require(throws: MachmanError.self) {
				try registry.rename(kept, to: "other")
			}
			#expect(error.code == .invalidState)
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/other"))
		}
	}

	@Test @MainActor func removingOrRenamingAUsedDiskIsRefused() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))
			let data = try #require(kept.config.disks.first)

			#expect(throws: MachmanError.self) { try registry.removeDisk(data, from: kept) }
			#expect(throws: MachmanError.self) {
				try registry.renameStorageDisk(id: data.id, of: kept, to: "renamed")
			}
			#expect(kept.config.disks == [data])
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/kept/renamed.raw"))
		}
	}

	@Test @MainActor func theReferencingVMStaysFree() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			try registry.delete(try #require(registry.vm(named: "alpha")))
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(registry.vm(named: "kept") != nil)
		}
	}

	// "kept 2/…" is not inside "kept".
	@Test @MainActor func aSiblingFolderIsNotInside() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept 2")
			let registry = try makePair(referencing: machmanVMDir + "/kept 2/data.raw")
			try registry.delete(try #require(registry.vm(named: "kept")))
			#expect(registry.vm(named: "kept") == nil)
		}
	}
}
