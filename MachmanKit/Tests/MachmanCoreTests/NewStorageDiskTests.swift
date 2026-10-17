//
//  NewStorageDiskTests.swift
//  MachmanCoreTests
//
//  D15: + Disk → New with an existing disk's name replaced main.raw with zeros (even under
//  a running VM) and added a second entry for the same file; "../other/x" wrote outside the
//  VM folder. A new disk now takes a name through the disk-name rule, must be new to the
//  VM's config AND folder, and its image is created exclusively.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct NewStorageDiskTests {
	private let mib: UInt64 = 1 << 20

	private func makeVM(_ name: String = "disks") throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	@Test func aNewDiskNeverReplacesAnExistingOne() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			try vm.addNewStorageDisk(name: "main", size: mib)
			let path = vm.configFilePath(file: "main.raw")
			let handle = try #require(FileHandle(forWritingAtPath: path))
			try handle.write(contentsOf: Data("marker".utf8))
			try handle.close()

			let error = try #require(throws: MachmanError.self) {
				try vm.addNewStorageDisk(name: "main", size: 64 * mib)
			}
			#expect(error.code == .alreadyExists)
			#expect(error.message == "This VM already has a disk named \u{201C}main\u{201D}")
			let data = try Data(contentsOf: URL(fileURLWithPath: path))
			#expect(data.count == Int(mib))
			#expect(data.prefix(6) == Data("marker".utf8))
			#expect(vm.disks.count == 1)
		}
	}

	@Test func anOrphanFileIsNotOverwritten() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			let path = vm.configFilePath(file: "orphan.raw")
			try Data("orphan".utf8).write(to: URL(fileURLWithPath: path))
			let error = try #require(throws: MachmanError.self) {
				try vm.addNewStorageDisk(name: "orphan", size: mib)
			}
			#expect(error.code == .alreadyExists)
			#expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("orphan".utf8))
			#expect(vm.disks.isEmpty)
		}
	}

	@Test func pathsAndHiddenNamesAreRefused() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			try FileManager.default.createDirectory(
				atPath: machmanVMDir + "/other", withIntermediateDirectories: true)
			for bad in ["../other/x", "a/b", ".hidden", "", "a\tb"] {
				let error = try #require(throws: MachmanError.self, "\(bad)") {
					try vm.addNewStorageDisk(name: bad, size: mib)
				}
				#expect(error.code == .invalidArgument, "\(bad)")
			}
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/other/x.raw"))
			#expect(vm.disks.isEmpty)
		}
	}

	@Test func namesTrimAndSizesAlign() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			try vm.addNewStorageDisk(name: " data ", size: mib)
			#expect(vm.disks.first?.id == "storage:data")
			#expect(FileManager.default.fileExists(atPath: vm.configFilePath(file: "data.raw")))
			for size: UInt64 in [0, 1000] {
				#expect(throws: MachmanError.self) {
					try vm.addNewStorageDisk(name: "odd", size: size)
				}
			}
			#expect(!FileManager.default.fileExists(atPath: vm.configFilePath(file: "odd.raw")))
		}
	}

	// D24: vm.disk.resize only checked that the size grew, so a wire client could leave a raw
	// at a size VZ refuses at the next start ("Couldn’t attach main.raw"). Add's rule holds
	// for grow now.
	@Test func growRefusesASizeOffTheSectorGrid() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			try vm.addNewStorageDisk(name: "main", size: mib)
			let path = vm.configFilePath(file: "main.raw")
			for bad in [mib + 100, UInt64(Int64.max) + 512] {
				let error = try #require(throws: MachmanError.self, "\(bad)") {
					try vm.growStorageDisk(id: "storage:main", to: bad)
				}
				#expect(error.code == .invalidArgument)
				#expect(error.message == "A disk’s size must be a positive multiple of 512 bytes")
			}
			#expect(fileSize(atPath: path) == mib)
			try vm.growStorageDisk(id: "storage:main", to: 2 * mib)
			#expect(fileSize(atPath: path) == 2 * mib)
			#expect(vm.disks.first?.kind == .storage("main", 2 * mib))
		}
	}

	@Test func macSystemDiskDodgesAnOrphan() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM()
			let orphan = vm.configFilePath(file: "disk.raw")
			try Data("orphan".utf8).write(to: URL(fileURLWithPath: orphan))
			try vm.ensureMacSystemDisk(minimumSize: mib)
			#expect(vm.disks.map(\.id) == ["storage:disk-2"])
			#expect(try Data(contentsOf: URL(fileURLWithPath: orphan)) == Data("orphan".utf8))
		}
	}

	// D32 (review 4, high): Bootloader ▸ macOS… on a used EFI or kernel VM kept its storage
	// disk as the install target (the reuse rule is for retrying a failed macOS install), and
	// with only an image or ISO attached the new disk went after them — either way macOS
	// restores over a disk the user already had. Refusing the switch would fix it too.
	@Test("D32: preparing a macOS install from EFI never targets a disk the VM already had")
	func macInstallNeverTargetsAnExistingDisk() throws {
		try VMTestDir.withRedirectedDir {
			let linux = try makeVM("linux")
			try linux.addNewStorageDisk(name: "system", size: mib)
			let image = TestEnvironment.scratch + "d32-\(UUID().uuidString).raw"
			try Data(count: Int(mib)).write(to: URL(fileURLWithPath: image))
			defer { try? FileManager.default.removeItem(atPath: image) }
			let referencing = try makeVM("referencing")
			try referencing.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
			for vm in [linux, referencing] {
				let before = vm.disks
				do {
					try vm.ensureMacSystemDisk(minimumSize: mib)
				} catch {
					continue   // a refused switch keeps the user's disks
				}
				let target = vm.disks.first
				#expect(target.map { !before.contains($0) } == true,
					"\(vm.name) would install macOS onto \(String(describing: target?.id))")
			}
		}
	}

	// D32 (review 4): the reuse rule belongs to a retry — a Mac whose install failed (or a copy
	// of one) installs again onto its own first disk, switched on if it was off; a retry whose
	// first disk can't hold macOS gets a new one first instead.
	@Test("D32: a retry of a failed macOS install reuses its own first disk")
	func aRetryReusesItsOwnFirstDisk() throws {
		try VMTestDir.withRedirectedDir {
			let failed = MacOSBoot(
				installState: .failed("x"), minimumCPUCount: 2, minimumMemorySize: 1 << 30)
			let mac = try makeVM("retry")
			try mac.addNewStorageDisk(name: "macos", size: mib)
			try mac.addNewStorageDisk(name: "data", size: mib)
			try mac.setEnabled(
				disks: ["storage:macos": false], mounts: [:], console: [:], uart: [:])
			mac.boot = .macOS(failed)
			try mac.ensureMacSystemDisk(minimumSize: mib)
			#expect(mac.disks.map(\.id) == ["storage:macos", "storage:data"])
			#expect(mac.disks.first?.enabled == true)

			let isoFirst = try makeVM("iso-first")
			try isoFirst.addIsoDisk(isoUrl: URL(fileURLWithPath: "/isos/installer.iso"))
			isoFirst.boot = .macOS(failed)
			try isoFirst.ensureMacSystemDisk(minimumSize: mib)
			#expect(isoFirst.disks.map(\.id).first == "storage:disk")
			#expect(isoFirst.disks.count == 2)
		}
	}

	// D32 (review 4), K4: the switch sheet may name one of the VM's disks for macOS instead.
	// The install erases it: it goes first (VZ restores onto the first disk), switched on.
	@Test("D32: a disk picked for macOS goes first and is switched on")
	func aPickedDiskGoesFirst() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("picked")
			try vm.addNewStorageDisk(name: "system", size: mib)
			try vm.addNewStorageDisk(name: "spare", size: mib)
			try vm.setEnabled(
				disks: ["storage:spare": false], mounts: [:], console: [:], uart: [:])
			try vm.ensureMacSystemDisk(onto: "storage:spare", minimumSize: mib)
			#expect(vm.disks.map(\.id) == ["storage:spare", "storage:system"])
			#expect(vm.disks.first?.enabled == true)
			let saved = try VMConfig.load(name: "picked")
			#expect(saved.disks.map(\.id) == ["storage:spare", "storage:system"])
		}
	}

	// The picked disk is one of this VM's own that can hold macOS, and no other VM's config
	// names its file: erasing it would destroy that VM's disk. Its size is never a reason —
	// the sheet warns about a small disk (K15), and these are 1 MiB.
	@Test("D32: macOS refuses an ISO, a newer Machman's disk, another VM's disk or a gone one")
	func aPickedDiskIsOnlyThisVMs() throws {
		try VMTestDir.withRedirectedDir {
			let owner = try makeVM("owner")
			try owner.addNewStorageDisk(name: "system", size: mib)
			try owner.addNewStorageDisk(name: "shared", size: mib)
			try owner.addIsoDisk(isoUrl: URL(fileURLWithPath: "/isos/installer.iso"))
			let newer = try JSONDecoder().decode(
				VMDisk.self, from: Data(#"{"kind":{"nvme":{"_0":"fast"}}}"#.utf8))
			owner.disks.append(newer)
			try owner.saveVMConfig()
			let other = try makeVM("other")
			try other.addDisk(disk: VMDisk(kind: .fromUrl(
				URL(fileURLWithPath: owner.configFilePath(file: "shared.raw")))))
			let registry = VMRegistry()
			let vm = try #require(registry.vm(named: "owner"))
			@MainActor func refusal(_ id: String) -> MachmanError? {
				registry.macInstallTargetRefusal(id, of: vm)
			}
			#expect(refusal("storage:system") == nil)
			#expect(refusal("iso:file:///isos/installer.iso")?.message
				== "macOS can\u{2019}t be installed on an ISO")
			#expect(refusal(newer.id)?.message
				== "macOS can\u{2019}t be installed on a disk a newer Machman added")
			#expect(refusal("storage:shared")?.message == "other also uses \u{201C}shared.raw"
				+ "\u{201D}, so macOS can\u{2019}t be installed on it")
			#expect(refusal("storage:gone")?.code == .notFound)
		}
	}

	// D34 (review 4): vm.disk.add appended any image or iso path, so the same raw picked twice
	// (or the VM's own raw by reference) made two entries with one id — the inspector couldn't
	// tell them apart, removing one removed both — and both attached writable at a start.
	@Test("D34: a file the VM already attaches can't be added a second time")
	func aFileIsAttachedOnce() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("twice")
			try vm.addNewStorageDisk(name: "system", size: mib)
			let image = TestEnvironment.scratch + "d34-\(UUID().uuidString).raw"
			try Data(count: Int(mib)).write(to: URL(fileURLWithPath: image))
			let link = image + ".link"
			try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: image)
			defer {
				try? FileManager.default.removeItem(atPath: image)
				try? FileManager.default.removeItem(atPath: link)
			}
			try vm.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
			let again: [VMDisk] = [
				VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))),
				VMDisk(kind: .fromUrl(URL(fileURLWithPath: link))),
				VMDisk(kind: .iso(URL(fileURLWithPath: image))),
				VMDisk(kind: .fromUrl(URL(fileURLWithPath: vm.configFilePath(file: "system.raw")))),
			]
			for disk in again {
				let error = try #require(throws: MachmanError.self, "\(disk.id)") {
					try vm.addDisk(disk: disk)
				}
				#expect(error.code == .alreadyExists)
			}
			#expect(vm.disks.count == 2)
			let reloaded = try VMConfig.load(name: "twice")
			#expect(reloaded.disks.count == 2)
		}
	}

	// D36 (review 4): on the default case-insensitive volume, Data → data found the disk's
	// own file at the new name and was refused as "already in the VM's folder"; a kernel
	// tag V1 → v1 the same. Only the letter case changes, so the rename goes through.
	@Test("D36: a disk or kernel tag renamed only in letter case is renamed")
	func aCaseOnlyRenameGoesThrough() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("cases")
			try vm.addNewStorageDisk(name: "Data", size: mib)
			try vm.renameStorageDisk(id: "storage:Data", to: "data")
			#expect(vm.disks.map(\.id) == ["storage:data"])
			let files = try FileManager.default.contentsOfDirectory(
				atPath: vm.configFilePath(file: ""))
			#expect(files.contains("data.raw") && !files.contains("Data.raw"), "\(files)")

			let src = TestEnvironment.scratch + "d36-\(UUID().uuidString)"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let kernelsDir = vm.kernelsDirPath()
			let kernel = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: kernelsDir, tag: "V1")
			let moved = try KernelStore.rename(path: kernel, kernelsDir: kernelsDir, newTag: "v1")
			#expect(FileManager.default.fileExists(atPath: moved))
			let tags = try FileManager.default.contentsOfDirectory(atPath: kernelsDir + "/kernel")
			#expect(tags == ["v1"])
		}
	}

	// D40 (review 4): VM folders were made 0755 and raw disks 0644, so only ~/Library's own
	// mode kept other accounts out; a library moved with MachmanDataDir to /Users/Shared or
	// another volume let every local account read every guest's disk.
	@Test("D40: a new VM's folder and a new disk are readable by their owner only")
	func newVMFilesArePrivate() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("private")
			try vm.addNewStorageDisk(name: "system", size: mib)
			let fm = FileManager.default
			func mode(_ path: String) throws -> Int {
				let attributes = try fm.attributesOfItem(atPath: path)
				return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
			}
			let folder = try mode(vm.configFilePath(file: ""))
			let disk = try mode(vm.configFilePath(file: "system.raw"))
			#expect(folder & 0o077 == 0, "folder \(String(folder, radix: 8))")
			#expect(disk & 0o077 == 0, "disk \(String(disk, radix: 8))")
		}
	}

	// D40 (review 4), with K5: everything Machman makes for a new VM is owner-only — its
	// config, a disk copied in, a copy's folder and config, and the library itself when
	// Machman creates it — while a VM made before keeps the modes it has.
	@Test("D40: a new VM's config, an imported disk, a copy and a new library are owner-only")
	func everythingNewIsPrivate() throws {
		try VMTestDir.withRedirectedDir {
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir))
			let vm = try makeVM("fresh")
			#expect(try posixMode(machmanVMDir) == 0o700)
			#expect(try posixMode(vm.configPath()) == 0o600)
			let source = TestEnvironment.scratch + "d40-\(UUID().uuidString).raw"
			try Data(count: Int(mib)).write(to: URL(fileURLWithPath: source))
			chmod(source, 0o644)
			defer { try? FileManager.default.removeItem(atPath: source) }
			let imported = try DiskImport.importFile(
				src: source, vmDir: vm.vmDirPath(), takenStorageNames: [])
			try vm.addDisk(disk: imported)
			guard case .storage(let name, _) = imported.kind else {
				Issue.record("an imported raw is an owned storage disk")
				return
			}
			#expect(try posixMode(vm.configFilePath(file: "\(name).raw")) == 0o600)
			let copy = try VMCopier.copy(VMCopyRequest(
				sourceDir: vm.vmDirPath(), destinationParent: machmanVMDir, newName: "copy"))
			#expect(try posixMode(copy) == 0o700)
			#expect(try posixMode(copy + "/config") == 0o600)
		}
	}

	@Test("D40: a VM made before keeps its folder's and config's modes")
	func olderModesStay() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("older")
			chmod(machmanVMDir, 0o755)
			chmod(vm.vmDirPath(), 0o755)
			chmod(vm.configPath(), 0o644)
			try vm.setCPUCount(1)   // a save over the config that is there
			_ = VMRegistry()        // a scan of the library that is there
			try vm.addNewStorageDisk(name: "data", size: mib)
			#expect(try posixMode(machmanVMDir) == 0o755)
			#expect(try posixMode(vm.vmDirPath()) == 0o755)
			#expect(try posixMode(vm.configPath()) == 0o644)
			#expect(try posixMode(vm.configFilePath(file: "data.raw")) == 0o600)   // a new disk
		}
	}

	private func posixMode(_ path: String) throws -> Int {
		let attributes = try FileManager.default.attributesOfItem(atPath: path)
		return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
	}

	@Test func importNamesFollowTheRule() {
		#expect(VMCopier.storageName(
			for: URL(fileURLWithPath: "/x/.hidden.raw"), taken: []) == "hidden")
		#expect(VMCopier.storageName(
			for: URL(fileURLWithPath: "/x/disk.img"), taken: ["disk"]) == "disk-2")
	}
}
