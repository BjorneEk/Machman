//
//  GuestSetupPinTests.swift
//  MachmanCoreTests
//
//  What a VM serves (S67): the Guest Setup script it is pinned to, whatever build of Machman
//  writes its payload — an app update never moves a pin. The pin survives a reset of the
//  setup state and travels with a copy.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (VMConfig in a redirected library, its store beside it).
@MainActor
struct GuestSetupPinTests {
	static func script(_ version: Int, _ body: String) -> Data {
		Data("#!/bin/sh\nSCRIPT_VERSION=\(version)\n\(body)\n".utf8)
	}

	static func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	static func served(_ payload: URL) throws -> Data {
		try Data(contentsOf: payload.appendingPathComponent(GuestSetupInstaller.scriptName))
	}

	// machman.env's SETUP_CKSUM, as the guest's payload_check reads it.
	static func setupCksum(_ payload: URL) throws -> String? {
		let env = try String(
			contentsOf: payload.appendingPathComponent(GuestInstallerWriter.environmentFileName),
			encoding: .utf8)
		let key = GuestInstallerWriter.checksumKey + "="
		return env.components(separatedBy: "\n").first { $0.hasPrefix(key) }
			.map { String($0.dropFirst(key.count)).trimmingCharacters(in: ["'"]) }
	}

	// The cksum the guest computes over its copy: the script, then the extras present.
	static func cksumOfServedFiles(_ payload: URL) throws -> String {
		var data = try served(payload)
		for name in ["host_key.pub", "host_machine_key.pub"]
			+ [GuestSetupInstallerInfo.mountsFileName] {
			if let more = try? Data(contentsOf: payload.appendingPathComponent(name)) {
				data.append(more)
			}
		}
		return POSIXChecksum.cksum(data)
	}

	@Test("S67: a pinned VM's payload carries its pinned script and that script's cksum")
	func aPinnedVMServesItsScript() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try Self.makeVM("pinned")
			let custom = Self.script(7, "echo pinned")
			let entry = try GuestSetupStore.current.add(
				custom, kind: GuestSetupStore.Kind.custom, vm: "pinned", label: "pinned.sh")
			var setup = GuestSetupConfig()
			setup.script = entry.id
			vm.setup = setup
			let (payload, _) = try GuestSetupInstaller.writePayload(for: vm)
			#expect(try Self.served(payload) == custom)
			#expect(try Self.setupCksum(payload) == Self.cksumOfServedFiles(payload))
			#expect(try Self.served(payload) != GuestSetupStore.thisBuild.data)
		}
	}

	@Test(
		"""
		S67: after an app update a pinned VM keeps serving its script and a new VM gets the \
		new one
		""")
	func anAppUpdateKeepsThePin() throws {
		try VMTestDir.withRedirectedDir {
			let root = URL(fileURLWithPath: machmanSetupScriptsDir, isDirectory: true)
			let older = GuestSetupStore(
				root: root, builtIn: GuestSetupStore.Script(data: Self.script(7, "echo older")))
			let old = try Self.makeVM("old")
			var setup = GuestSetupConfig()
			setup.script = older.builtIn.entry.id
			old.setup = setup
			let (before, _) = try GuestSetupInstaller.writePayload(for: old, store: older)
			#expect(try Self.served(before) == older.builtIn.data)

			// The update: this build's Machman over the same store.
			let newer = GuestSetupStore(root: root)
			let (after, _) = try GuestSetupInstaller.writePayload(for: old, store: newer)
			#expect(try Self.served(after) == older.builtIn.data)
			let new = try Self.makeVM("new")
			let (fresh, _) = try GuestSetupInstaller.writePayload(for: new, store: newer)
			#expect(try Self.served(fresh) == newer.builtIn.data)
			#expect(newer.latest.id == newer.builtIn.entry.id)
			#expect(newer.entry(id: older.builtIn.entry.id) != nil)
		}
	}

	@Test("S67: resetting setup state keeps the VM's pin")
	func resetKeepsThePin() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try Self.makeVM("reset")
			var setup = GuestSetupConfig()
			setup.installed = true
			setup.scriptVersion = 7
			setup.script = "custom-0123456789ab"
			vm.setup = setup
			try vm.saveVMConfig()
			try vm.resetSetup()
			#expect(vm.setup?.script == "custom-0123456789ab")
			#expect(vm.setup?.installed == nil && vm.setup?.scriptVersion == nil)
			#expect(try VMConfig.load(name: "reset").setup?.script == "custom-0123456789ab")
			// Nothing left to keep: the state goes as before.
			vm.setup?.script = nil
			try vm.resetSetup()
			#expect(vm.setup == nil)
		}
	}
}
