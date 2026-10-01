//
//  RegistryDeleteTests.swift
//  MachmanTests
//
//  vm.delete's engine half (E16): the registry forgets a VM only once its folder is gone.
//  A folder the delete cannot empty (read-only here) keeps the VM listed, so the client's
//  error and the list agree and the user can retry.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct RegistryDeleteTests {
	@MainActor
	private func makeVM(_ name: String) throws {
		try VMConfig.createNewVMDirectory(name: name)
		_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
	}

	@Test @MainActor func aFailedFolderDeleteKeepsTheVM() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("alpha")
			let registry = VMRegistry()
			let vm = try #require(registry.vm(named: "alpha"))
			let dir = machmanVMDir + "/alpha"
			// Read-only folder: removeItem cannot unlink its entries (Cocoa 513).
			#expect(chmod(dir, 0o555) == 0)
			defer { chmod(dir, 0o755) }   // before the redirect's cleanup removes it

			#expect(throws: (any Error).self) { try registry.delete(vm) }
			#expect(registry.vm(named: "alpha") != nil)
			#expect(FileManager.default.fileExists(atPath: dir + "/config"))
		}
	}

	@Test @MainActor func deleteRemovesTheVMAndItsFolder() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("alpha")
			let registry = VMRegistry()
			let vm = try #require(registry.vm(named: "alpha"))

			try registry.delete(vm)

			#expect(registry.vm(named: "alpha") == nil)
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/alpha"))
		}
	}
}
