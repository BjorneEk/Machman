//
//  RegistryCreateTests.swift
//  MachmanTests
//
//  D19: New VM picked "new-VM<n>" against the in-memory list only and wrote its config into
//  whatever folder had that name. A folder the scan skipped — its config damaged, and still
//  the user's to restore — lost that config, and its disks became the new VM's. The name is
//  now taken on disk too, and the folder is made exclusively.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct RegistryCreateTests {
	@Test @MainActor func aSkippedFolderKeepsItsConfig() throws {
		try VMTestDir.withRedirectedDir {
			let skipped = machmanVMDir + "/new-VM1"
			try FileManager.default.createDirectory(
				atPath: skipped, withIntermediateDirectories: true)
			let damaged = Data("{\"name\": \"new-VM1\", \"memorySize\": ".utf8)
			try damaged.write(to: URL(fileURLWithPath: skipped + "/config"))
			let registry = VMRegistry()
			#expect(registry.vm(named: "new-VM1") == nil)   // the scan skipped it

			let created = try registry.create()
			#expect(created.name == "new-VM2")   // before: new-VM1, over the damaged config
			#expect(try Data(contentsOf: URL(fileURLWithPath: skipped + "/config")) == damaged)
		}
	}

	@Test @MainActor func aStrayFileTakesTheNameToo() throws {
		try VMTestDir.withRedirectedDir {
			try FileManager.default.createDirectory(
				atPath: machmanVMDir, withIntermediateDirectories: true)
			FileManager.default.createFile(
				atPath: machmanVMDir + "/new-VM1", contents: Data("x".utf8))
			let registry = VMRegistry()
			#expect(try registry.create().name == "new-VM2")
		}
	}

	@Test @MainActor func theFolderIsMadeOnlyOnce() throws {
		try VMTestDir.withRedirectedDir {
			let first = try VMConfig.createNewVMDirectory(name: "solo")
			let second = try VMConfig.createNewVMDirectory(name: "solo")
			#expect(first)
			#expect(!second)
		}
	}
}
