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
}
