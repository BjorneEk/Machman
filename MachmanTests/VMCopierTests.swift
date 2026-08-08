//
//  VMCopierTests.swift
//  MachmanTests
//
//  VMCopier on bare temp directories — no VMTestDir lock (the copier takes explicit paths),
//  no Virtualization runtime. Source configs are written by hand-encoding VMConfig with the
//  persistence coder, never via saveVMConfig (which points at the global dir).
//

import Foundation
import Testing
import Virtualization
import MachmanAPI
@testable import MachmanCore

struct VMCopierTests {
	private func makeLibrary() throws -> String {
		let dir = NSTemporaryDirectory() + "vmcopier-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	@discardableResult
	private func makeSourceVM(
		in library: String, name: String = "src",
		disks: [VMDisk] = [VMDisk(kind: .storage("disk", 0))],
		mounts: [HostMountPoint] = [],
		macAddress: String? = "aa:bb:cc:dd:ee:01",
		boot: BootConfig = .efi,
		extraFiles: [String: Data] = [:]
	) throws -> String {
		let dir = library + "/" + name
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.name = name
		config.disks = disks
		config.mountPoints = mounts
		config.macAddress = macAddress
		config.boot = boot
		let encoder = JSONEncoder()
		try encoder.encode(config).write(to: URL(fileURLWithPath: dir + "/config"))
		for disk in disks {
			if case .storage(let diskName, _) = disk.kind {
				try Data("rawbytes-\(diskName)".utf8)
					.write(to: URL(fileURLWithPath: dir + "/\(diskName).raw"))
			}
		}
		for (file, data) in extraFiles {
			try data.write(to: URL(fileURLWithPath: dir + "/" + file))
		}
		return dir
	}

	private func loadConfig(_ dir: String) throws -> VMConfig {
		try JSONDecoder().decode(
			VMConfig.self, from: try Data(contentsOf: URL(fileURLWithPath: dir + "/config")))
	}

	@Test func clonedDiskIsIndependent() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/disk.raw"))
			== Data("rawbytes-disk".utf8))

		// Mutating the source afterwards must not touch the copy.
		try Data("changed".utf8).write(to: URL(fileURLWithPath: src + "/disk.raw"))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/disk.raw"))
			== Data("rawbytes-disk".utf8))
		let values = try URL(fileURLWithPath: dst + "/disk.raw")
			.resourceValues(forKeys: [.isExcludedFromBackupKey])
		#expect(values.isExcludedFromBackup == true)
	}

	@Test func referenceRewritesToTheSourceFile() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			diskPolicies: ["storage:disk": .reference]))
		let config = try loadConfig(dst)
		guard case .fromUrl(let url) = config.disks.first?.kind else {
			Issue.record("expected a fromUrl rewrite")
			return
		}
		#expect(url.path == src + "/disk.raw")
		#expect(!FileManager.default.fileExists(atPath: dst + "/disk.raw"))
	}

	@Test func omittedDiskLeavesNoTrace() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			diskPolicies: ["storage:disk": .omit]))
		#expect(try loadConfig(dst).disks.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: dst + "/disk.raw"))
	}

	@Test func macRegeneratedOnlyWhenAsked() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)

		let kept = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "kept",
			regenerateMAC: false))
		#expect(try loadConfig(kept).macAddress == "aa:bb:cc:dd:ee:01")

		let fresh = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "fresh",
			regenerateMAC: true))
		let mac = try #require(try loadConfig(fresh).macAddress)
		#expect(mac != "aa:bb:cc:dd:ee:01")
		#expect(VZMACAddress(string: mac) != nil)
	}

	@Test func identityAndSessionFilesDropped() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library, extraFiles: [
			"vm_identifier": Data("id".utf8),
			"console.log": Data("boot".utf8),
			"restore.ipsw": Data("ipsw".utf8),
			"efi_vars.fd": Data("efi".utf8),
			"notes.txt": Data("notes".utf8),
		])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let fm = FileManager.default
		#expect(!fm.fileExists(atPath: dst + "/vm_identifier"))
		#expect(!fm.fileExists(atPath: dst + "/console.log"))
		#expect(!fm.fileExists(atPath: dst + "/restore.ipsw"))
		#expect(fm.fileExists(atPath: dst + "/efi_vars.fd"))
		#expect(fm.fileExists(atPath: dst + "/notes.txt"))
	}

	@Test func macOSGuestGetsAFreshMachineID() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let sourceID = VZMacMachineIdentifier().dataRepresentation
		let src = try makeSourceVM(in: library, extraFiles: [
			"mac_hardware_model": Data("model".utf8),
			"mac_aux.img": Data("aux".utf8),
			"mac_machine_id": sourceID,
		])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			guestKind: .macOS))
		let fm = FileManager.default
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_hardware_model"))
			== Data("model".utf8))
		#expect(try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_aux.img"))
			== Data("aux".utf8))
		let newID = try Data(contentsOf: URL(fileURLWithPath: dst + "/mac_machine_id"))
		#expect(newID != sourceID)
		#expect(VZMacMachineIdentifier(dataRepresentation: newID) != nil)
		_ = fm
	}

	@Test func safeFlagsAndMountFilterCarried() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let keepMount = HostMountPoint(path: "/Users/x/keep", tag: "keep")
		let dropMount = HostMountPoint(path: "/Users/x/drop", tag: "drop")
		let src = try makeSourceVM(
			in: library,
			disks: [VMDisk(kind: .storage("disk", 0), safe: false)],
			mounts: [keepMount, dropMount])

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			includedMountIDs: [keepMount.id.uuidString]))
		let config = try loadConfig(dst)
		#expect(config.disks.first?.safe == false)
		#expect(config.mountPoints.map(\.tag) == ["keep"])
	}

	@Test func existingDestinationRefused() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		try FileManager.default.createDirectory(
			atPath: library + "/dup", withIntermediateDirectories: true)

		#expect(throws: MachmanError.self) {
			try VMCopier.copy(VMCopyRequest(
				sourceDir: src, destinationParent: library, newName: "dup"))
		}
		// No staging residue either.
		let leftovers = try FileManager.default.contentsOfDirectory(atPath: library)
			.filter { $0.hasPrefix(VMCopier.stagingPrefix) }
		#expect(leftovers.isEmpty)
	}

	@Test func copyResetsHistoryAndAutostart() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library)
		let srcConfig = try loadConfig(src)
		srcConfig.lastRan = Date()
		srcConfig.totalRuntimeSeconds = 42
		srcConfig.startPolicy = StartPolicy(windowed: false, safe: false, autostart: true)
		try JSONEncoder().encode(srcConfig)
			.write(to: URL(fileURLWithPath: src + "/config"))

		let dst = try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup"))
		let config = try loadConfig(dst)
		#expect(config.name == "dup")
		#expect(config.lastRan == nil)
		#expect(config.totalRuntimeSeconds == 0)
		#expect(config.startPolicy.autostart == false)
		#expect(config.startPolicy.windowed == false)   // the rest of the policy carries
	}

	@Test func progressReportsMonotonicallyToTotal() throws {
		let library = try makeLibrary()
		defer { try? FileManager.default.removeItem(atPath: library) }
		let src = try makeSourceVM(in: library, extraFiles: [
			"notes.txt": Data(repeating: 0xAB, count: 512 * 1024),
		])

		final class Reports: @unchecked Sendable {
			let lock = NSLock()
			var values: [(UInt64, UInt64)] = []
			func add(_ copied: UInt64, _ total: UInt64) {
				lock.lock()
				values.append((copied, total))
				lock.unlock()
			}
		}
		let reports = Reports()
		try VMCopier.copy(VMCopyRequest(
			sourceDir: src, destinationParent: library, newName: "dup",
			progress: { reports.add($0, $1) }))

		let values = reports.values
		#expect(!values.isEmpty)
		#expect(values.map(\.0) == values.map(\.0).sorted())      // non-decreasing
		#expect(values.last?.0 == values.last?.1)                 // ends at total
	}
}
