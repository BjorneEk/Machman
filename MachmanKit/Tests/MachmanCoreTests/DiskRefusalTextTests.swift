//
//  DiskRefusalTextTests.swift
//  MachmanTests
//
//  W3: disk, mount and kernel refusals showed ids ("no disk 'storage:data' on X"), raw byte
//  counts ("…is already 34359738368 bytes") and straight-quoted lowercase text next to the
//  desktop's own wording. They read in sentence case now, sizes in binary GB, and the
//  desktop's field-problem twins word for word.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct DiskRefusalTextTests {
	private func refusal(_ body: () throws -> Void) -> String? {
		do {
			try body()
			return nil
		} catch let error as MachmanError {
			return error.message
		} catch {
			return "\(error)"
		}
	}

	@Test @MainActor func diskAndMountRefusalsMatchTheDesktop() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try VMRegistry().create()
			let config = vm.config
			try config.addNewStorageDisk(name: "data", size: 1 << 20)
			try config.addNewStorageDisk(name: "scratch", size: 1 << 20)
			#expect(refusal { try config.growStorageDisk(id: "storage:data", to: 512) }
				== "Disks only grow \u{2014} enter more than \(ByteSize.display(1 << 20))")
			#expect(refusal { try config.renameStorageDisk(id: "storage:scratch", to: "data") }
				== "This VM already has a disk named \u{201C}data\u{201D}")

			try config.addMountPoint(HostMountPoint(path: "/tmp", tag: "docs"))
			try config.addMountPoint(HostMountPoint(path: "/var", tag: "logs"))
			let logs = try #require(config.mountPoints.first { $0.tag == "logs" })
			#expect(refusal { try config.setMountTag(id: logs.id.uuidString, tag: "docs") }
				== "This VM already has a mount tagged \u{201C}docs\u{201D}")

			#expect(refusal {
				try config.setEnabled(
					disks: ["storage:nope": true], mounts: [:], console: [:], uart: [:])
			} == "\(config.name) no longer has that disk")
		}
	}

	@Test func aQcow2ImportSaysWhatToDo() throws {
		let dir = TestEnvironment.scratch + "qcow-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let src = dir + "/ubuntu.qcow2"
		try Data([0x51, 0x46, 0x49, 0xFB] + [UInt8](repeating: 0, count: 508))
			.write(to: URL(fileURLWithPath: src))
		let message = refusal {
			_ = try DiskImport.importFile(src: src, vmDir: dir, takenStorageNames: [])
		}
		#expect(message == "Machman can\u{2019}t use qcow2 images \u{2014} convert to raw first "
			+ "(qemu-img convert -O raw)")
		#expect(message == Samples.failedQcow2Import().message)
	}

	@Test func aTakenKernelTagNamesTheFile() throws {
		let dir = TestEnvironment.scratch + "ktag-\(UUID().uuidString)"
		let kernels = dir + "/kernels"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let src = dir + "/vmlinuz"
		try Data("kernel".utf8).write(to: URL(fileURLWithPath: src))
		let first = try KernelStore.promote(
			role: .kernel, sourcePath: src, kernelsDir: kernels, tag: "stable")
		_ = try KernelStore.promote(
			role: .kernel, sourcePath: src, kernelsDir: kernels, tag: "next")
		#expect(refusal {
			_ = try KernelStore.rename(path: first, kernelsDir: kernels, newTag: "next")
		} == "\u{201C}next\u{201D} already holds a file named \u{201C}vmlinuz\u{201D}")
	}
}
