//
//  PromotionMoveTests.swift
//  MachmanTests
//
//  E15: Save as New VM moves the shadow by ONE exclusive same-volume rename, never a copy.
//  A cross-volume layout is refused before anything moves (the sandbox has one volume, so
//  the rename seam reports EXDEV), and a name that appears during the save is never
//  replaced — plain rename(2) silently replaces an empty directory.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct PromotionMoveTests {
	@Test @MainActor func aCrossVolumeSaveIsRefusedAndLeavesTheRunIntact() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make()
			defer { host.removeLibrary() }
			let rename = host.registry.renameExclusive
			host.registry.renameExclusive = { _, _ in EXDEV }

			let error = try #require(throws: MachmanError.self) {
				try host.registry.promoteRestrictedVM(to: "kept")
			}
			#expect(error.code == .invalidState)
			#expect(FileManager.default.fileExists(atPath: host.shadowDir + "/config"))
			#expect(host.registry.restrictedName == "alpha")
			#expect(machmanVMDir == host.runRoot)
			#expect(!FileManager.default.fileExists(atPath: host.library + "/kept"))

			// The refusal spent nothing: the same run still saves on one volume.
			host.registry.renameExclusive = rename
			_ = try host.registry.promoteRestrictedVM(to: "kept")
			#expect(FileManager.default.fileExists(atPath: host.library + "/kept/config"))
		}
	}

	@Test @MainActor func aNameTakenDuringTheSaveIsRefused() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make()
			defer { host.removeLibrary() }
			try FileManager.default.createDirectory(
				atPath: host.library + "/kept", withIntermediateDirectories: true)

			let error = try #require(throws: MachmanError.self) {
				try host.registry.promoteRestrictedVM(to: "kept")
			}
			#expect(error.code == .alreadyExists)
			#expect(FileManager.default.fileExists(atPath: host.shadowDir + "/config"))
			#expect(try FileManager.default.contentsOfDirectory(
				atPath: host.library + "/kept").isEmpty)
			#expect(host.registry.restrictedName == "alpha")
		}
	}
}
