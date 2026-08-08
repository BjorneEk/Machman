//
//  AdoptFromDiskTests.swift
//  MachmanTests
//
//  The registry mutator that registers directories appearing after the initial scan
//  (vm.copy now, safe-save promotion later).
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct AdoptFromDiskTests {
	@Test @MainActor func adoptFromDiskRegistersANewDirectory() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			#expect(registry.list().isEmpty)

			// A directory appears behind the registry's back (what a finished copy does).
			try VMConfig.createNewVMDirectory(name: "late")
			_ = try VMConfig(name: "late", memorySize: 2048, cpuCount: 2)

			let vm = try registry.adoptFromDisk(name: "late")
			#expect(vm.name == "late")
			#expect(registry.list().map(\.name) == ["late"])
		}
	}

	@Test @MainActor func adoptFromDiskRefusesAKnownName() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "known")
			_ = try VMConfig(name: "known", memorySize: 2048, cpuCount: 2)
			let registry = VMRegistry()

			#expect(throws: MachmanError.self) {
				_ = try registry.adoptFromDisk(name: "known")
			}
		}
	}

	@Test @MainActor func restrictedRegistryRefusesAdopt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "only")
			_ = try VMConfig(name: "only", memorySize: 2048, cpuCount: 2)
			let restricted = VMRegistry(only: "only")

			#expect(throws: MachmanError.self) {
				_ = try restricted.adoptFromDisk(name: "other")
			}
		}
	}

	@Test @MainActor func uniqueNameProbesTheInMemoryMap() throws {
		try VMTestDir.withRedirectedDir {
			for name in ["Debian copy", "Debian copy 2"] {
				try VMConfig.createNewVMDirectory(name: name)
				_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			}
			let registry = VMRegistry()
			#expect(registry.uniqueName(base: "Debian copy") == "Debian copy 3")
			#expect(registry.uniqueName(base: "Fresh copy") == "Fresh copy")
		}
	}
}
