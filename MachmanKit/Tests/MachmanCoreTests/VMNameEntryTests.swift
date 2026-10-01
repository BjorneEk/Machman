//
//  VMNameEntryTests.swift
//  MachmanCoreTests
//
//  C15: a VM name taken by rename or copy passes the shared VM-name rule before anything
//  moves ("../x" moved the VM out of the library, ".hidden" hid it from the next scan),
//  and a rename that fails leaves the config's name alone (it used to change before the
//  move, so later saves went to a directory that didn't exist).
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

@MainActor
struct VMNameEntryTests {
	private func makeRegistry() throws -> VMRegistry {
		try VMConfig.createNewVMDirectory(name: "alpha")
		_ = try VMConfig(name: "alpha", memorySize: 1 << 30, cpuCount: 2)
		return VMRegistry()
	}

	@Test func renameRefusesUnsafeNamesBeforeTouchingTheDisk() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makeRegistry()
			let vm = try #require(registry.vm(named: "alpha"))
			for bad in ["../x", ".hidden", "a/b", "x\ty", " y", "y ", ""] {
				let error = try #require(throws: MachmanError.self, "\(bad)") {
					try registry.rename(vm, to: bad)
				}
				#expect(error.code == .invalidArgument, "\(bad)")
			}
			let fm = FileManager.default
			#expect(fm.fileExists(atPath: machmanVMDir + "/alpha/config"))
			#expect(!fm.fileExists(atPath: machmanVMDir + "/../x"))
			#expect(registry.vm(named: "alpha") === vm)
			#expect(vm.config.name == "alpha")
		}
	}

	@Test func aFailedMoveLeavesTheNameAlone() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makeRegistry()
			let vm = try #require(registry.vm(named: "alpha"))
			// A stray directory the registry doesn't know (no config in it).
			try FileManager.default.createDirectory(
				atPath: machmanVMDir + "/stray", withIntermediateDirectories: true)
			let error = try #require(throws: MachmanError.self) {
				try registry.rename(vm, to: "stray")
			}
			#expect(error.code == .alreadyExists)
			#expect(vm.config.name == "alpha")
			#expect(FileManager.default.fileExists(atPath: vm.config.vmDirPath()))
			#expect(registry.vm(named: "alpha") === vm)
		}
	}

	@Test func copyNamesPassTheSameRule() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makeRegistry()
			let unsafe = try #require(throws: MachmanError.self) {
				try registry.checkNewVMName("../x")
			}
			#expect(unsafe.code == .invalidArgument)
			let taken = try #require(throws: MachmanError.self) {
				try registry.checkNewVMName("alpha")
			}
			#expect(taken.code == .alreadyExists)
			#expect(taken.message == "A VM named \u{201C}alpha\u{201D} already exists")
			try registry.checkNewVMName("beta")
			try registry.checkNewVMName("alpha copy")
		}
	}
}
