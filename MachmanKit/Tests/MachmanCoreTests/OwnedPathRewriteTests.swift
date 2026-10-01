//
//  OwnedPathRewriteTests.swift
//  MachmanTests
//
//  C12: absolute paths a config owns inside its VM folder (isos, in-folder images, kernels)
//  follow the folder when it moves (rename, Save as New VM) — and a copy keeps its fromUrl
//  references on the source's files, the rule a safe-run shadow's unsafe disks rely on.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct OwnedPathRewriteTests {
	private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

	@Test @MainActor func renameRepointsOwnedIsosAndInFolderImages() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "before")
			let cfg = try VMConfig(name: "before", memorySize: 2048, cpuCount: 2)
			let dir = machmanVMDir + "/before"
			for file in ["install.iso", "extra.img"] {
				try Data(file.utf8).write(to: url(dir + "/" + file))
			}
			var image = VMDisk(kind: .fromUrl(url(dir + "/extra.img")), safe: false)
			image.enabled = false
			cfg.disks = [
				VMDisk(kind: .iso(url(dir + "/install.iso"))),
				image,
				VMDisk(kind: .iso(url("/isos/x.iso"))),
				VMDisk(kind: .fromUrl(url("/imgs/y.img"))),
			]
			try cfg.saveVMConfig()

			try cfg.rename(to: "after")

			let after = machmanVMDir + "/after"
			let saved = try VMConfig.load(name: "after")
			#expect(saved.disks.map(\.kind) == [
				.iso(url(after + "/install.iso")),
				.fromUrl(url(after + "/extra.img")),
				.iso(url("/isos/x.iso")),
				.fromUrl(url("/imgs/y.img")),
			])
			#expect(saved.disks[1].safe == false && saved.disks[1].enabled == false)
			#expect(FileManager.default.fileExists(atPath: after + "/install.iso"))
			#expect(FileManager.default.fileExists(atPath: after + "/extra.img"))
		}
	}

	// The shadow's owned iso points into the run root, which promotion moves, then deletes.
	@Test @MainActor func promotionRepointsAnOwnedIso() throws {
		try VMTestDir.withRedirectedDir {
			let iso = machmanVMDir + "-lib/alpha/install.iso"
			let host = try SafeRunFixture.make(
				disks: [VMDisk(kind: .iso(url(iso)))], files: ["install.iso": Data("iso".utf8)])
			defer { host.removeLibrary() }
			// The shadow build re-pointed the owned iso at its own copy.
			let shadow = try SafeRunFixture.load(host.shadowDir)
			#expect(shadow.disks.map(\.kind) == [.iso(url(host.shadowDir + "/install.iso"))])

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			let moved = host.library + "/kept/install.iso"
			let saved = try SafeRunFixture.load(host.library + "/kept")
			#expect(saved.disks.map(\.kind) == [.iso(url(moved))])
			#expect(FileManager.default.fileExists(atPath: moved))
		}
	}

	// .copied: the copy's own iso follows, its fromUrl keeps naming the source's file.
	@Test func aCopyKeepsInFolderReferencesOnTheSource() throws {
		let library = TestEnvironment.scratch + "owned-copy-\(UUID().uuidString)"
		let src = library + "/src"
		try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: library) }
		for file in ["install.iso", "extra.img"] {
			try Data(file.utf8).write(to: url(src + "/" + file))
		}
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"src","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.disks = [
			VMDisk(kind: .iso(url(src + "/install.iso"))),
			VMDisk(kind: .fromUrl(url(src + "/extra.img")), safe: false),
		]
		try SafeRunFixture.write(config, to: src)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "copy"))

		let copied = try SafeRunFixture.load(dst)
		#expect(copied.disks.map(\.kind) == [
			.iso(url(dst + "/install.iso")),
			.fromUrl(url(src + "/extra.img")),
		])
	}
}
