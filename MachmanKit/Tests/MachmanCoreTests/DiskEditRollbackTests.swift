//
//  DiskEditRollbackTests.swift
//  MachmanCoreTests
//
//  D22: removing a disk deleted its file before saving, and renaming one moved its file
//  before saving — a failed save left the config naming a file that was gone (“Couldn’t
//  attach disk.raw” at the next start), or the daemon's copy without a disk the file still
//  backed. The config is saved first now, and a failed save puts the file back. Saves are
//  made to fail by putting a directory where the config's atomic rename has to land.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct DiskEditRollbackTests {
	private let mib: UInt64 = 1 << 20
	private let fm = FileManager.default

	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	// Every later save of this VM fails: rename(2) can't replace a non-empty directory.
	private func breakSaves(of vm: VMConfig) throws {
		try fm.removeItem(atPath: vm.configPath())
		try fm.createDirectory(atPath: vm.configPath(), withIntermediateDirectories: true)
		try Data("x".utf8).write(to: URL(fileURLWithPath: vm.configPath() + "/keep"))
		#expect(throws: (any Error).self) { try vm.saveVMConfig() }
	}

	@Test func aFailedSaveKeepsARemovedDiskAndItsFile() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("remove")
			try vm.addNewStorageDisk(name: "data", size: mib)
			let disk = try #require(vm.disks.first)
			try breakSaves(of: vm)

			#expect(throws: (any Error).self) { try vm.deleteDisk(disk: disk) }
			#expect(vm.disks == [disk])
			#expect(fm.fileExists(atPath: vm.configFilePath(file: "data.raw")))
		}
	}

	@Test func aFailedSaveMovesARenamedDiskBack() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("rename")
			try vm.addNewStorageDisk(name: "data", size: mib)
			try breakSaves(of: vm)

			#expect(throws: (any Error).self) {
				try vm.renameStorageDisk(id: "storage:data", to: "renamed")
			}
			#expect(vm.disks.map(\.id) == ["storage:data"])
			#expect(fm.fileExists(atPath: vm.configFilePath(file: "data.raw")))
			#expect(!fm.fileExists(atPath: vm.configFilePath(file: "renamed.raw")))
		}
	}

	// The kernel-file re-tag has the same shape: KernelStore moves, then the config saves.
	@Test func aFailedSaveMovesARetaggedKernelBack() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("retag")
			let src = TestEnvironment.scratch + "rollback-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? fm.removeItem(atPath: src) }
			let old = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: vm.kernelsDirPath(), tag: "v1")
			try vm.setKernelBoot(enabled: true)
			try vm.updateKernelSettings(LinuxKernelBoot(
				kernelPath: old, initialRamdiskPath: nil, commandLine: ""))
			try vm.setKernelOverride(forFileAt: old, commandLine: "quiet", enabled: true)
			let overrides = vm.kernelOverrides
			try breakSaves(of: vm)

			#expect(throws: (any Error).self) { try vm.renameKernelFile(path: old, to: "v2") }
			#expect(vm.kernelSettings?.kernelPath == old)
			#expect(vm.boot == .linuxKernel(LinuxKernelBoot(
				kernelPath: old, initialRamdiskPath: nil, commandLine: "")))
			#expect(vm.kernelOverrides == overrides)
			#expect(fm.fileExists(atPath: old))
			#expect(!fm.fileExists(atPath: vm.kernelsDirPath() + "/kernel/v2"))
		}
	}

	// Review F3: once the config saved, the disk IS removed. A file that won't delete then
	// (here an owned iso in a read-only subfolder) used to throw — "Removing a disk failed"
	// while the desktop, with no listChanged, kept showing the disk. It stays as an orphan
	// now, and a warning names it.
	@Test func aFileThatWontDeleteAfterTheSaveIsReportedNotThrown() async throws {
		var registry: VMRegistry!
		var stream: AsyncStream<VMEvent>!
		var iso = ""
		try VMTestDir.withRedirectedDir {
			_ = try makeVM("orphan")
			registry = VMRegistry()
			let vm = try #require(registry.vm(named: "orphan"))
			let folder = vm.config.configFilePath(file: "isos")
			try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
			iso = folder + "/netinst.iso"
			try Data("iso".utf8).write(to: URL(fileURLWithPath: iso))
			try vm.config.addIsoDisk(isoUrl: URL(fileURLWithPath: iso))
			let disk = try #require(vm.config.disks.first)
			try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
			defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
			stream = registry.events.stream()

			try registry.removeDisk(disk, from: vm)

			registry.events.emit(.listChanged)   // the end of what removeDisk said
			#expect(vm.config.disks.isEmpty)
			#expect(try VMConfig.load(name: "orphan").disks.isEmpty)
			#expect(fm.fileExists(atPath: iso))
		}
		var warnings: [String] = []
		for await event in stream {
			if case .log(_, .warning, let message) = event { warnings.append(message) }
			if case .listChanged = event { break }
		}
		#expect(warnings == [
			"\u{201C}netinst.iso\u{201D} couldn\u{2019}t be deleted from the VM\u{2019}s folder "
				+ "\u{2014} remove it by hand.",
		])
	}
}
