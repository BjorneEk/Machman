//
//  GuestSetupStoreInfoTests.swift
//  MachmanCoreTests
//
//  The Guest Setup store as the engine serves it (S67): every VM with Guest Setup lists the
//  store with the latest build's script marked, the script it serves, and the entry its last
//  report's script cksum matches.
//

import Foundation
import Testing
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (the engine's VMInfo over a redirected library and its store).
@MainActor
struct GuestSetupStoreInfoTests {
	static func withVM<T>(_ body: (LocalMachman, VirtualMachine) throws -> T) throws -> T {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			try vm.config.addDevice(GuestDevice(kind: .guestSetup))
			return try body(LocalMachman(registry: registry), vm)
		}
	}

	static func report(_ cksum: String) -> GuestReport {
		GuestReport.parse("SCRIPT_VERSION=8\nSTATUS=ok\nSCRIPT_CKSUM=\(cksum)")
	}

	@Test(
		"""
		S67: a report's SCRIPT_CKSUM names the stored entry it matches, and an unmatched one \
		names none
		""")
	func theReportedCksumNamesItsEntry() throws {
		try Self.withVM { api, vm in
			let custom = Data("#!/bin/sh\nSCRIPT_VERSION=8\necho mine\n".utf8)
			let entry = try GuestSetupStore.current.add(
				custom, kind: GuestSetupStore.Kind.custom, vm: vm.config.name)
			try Self.report(entry.cksum).apply(to: vm.config, stampedAt: Date())
			#expect(api.info(for: vm).setup?.installedScript == entry.id)
			try Self.report(GuestSetupStore.thisBuild.entry.cksum)
				.apply(to: vm.config, stampedAt: Date())
			#expect(api.info(for: vm).setup?.installedScript
				== GuestSetupStore.thisBuild.entry.id)
			try Self.report("1 2").apply(to: vm.config, stampedAt: Date())
			let setup = api.info(for: vm).setup
			#expect(setup?.installedScript == nil)
			#expect(setup?.scriptVersion == 8)
		}
	}

	@Test("S67: an unpinned VM serves this build's script, which the list marks latest")
	func anUnpinnedVMServesThisBuild() throws {
		try Self.withVM { api, vm in
			try GuestSetupStore.current.add(
				Data("#!/bin/sh\nSCRIPT_VERSION=99\necho mine\n".utf8),
				kind: GuestSetupStore.Kind.custom, vm: "elsewhere", label: "mine.sh")
			let setup = try #require(api.info(for: vm).setup)
			let build = GuestSetupStore.thisBuild.entry.id
			#expect(setup.servedScript == build)
			#expect(setup.scripts?.filter { $0.latest == true }.map(\.id) == [build])
			let custom = try #require(setup.scripts?.first { $0.kind == "custom" })
			#expect(custom.label == "mine.sh" && custom.vm == "elsewhere")
			#expect(custom.version == 99 && custom.latest == nil && custom.addedAt != nil)
			// Without Guest Setup the VM lists no store.
			try vm.config.removeDevice(kind: .guestSetup)
			#expect(api.info(for: vm).setup?.scripts == nil)
		}
	}

	@Test("S67: a pin naming no stored script is refused and changes nothing")
	func aPinNeedsAStoredScript() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "pin")
			let vm = try VMConfig(name: "pin", memorySize: 1 << 30, cpuCount: 2)
			let custom = Data("#!/bin/sh\nSCRIPT_VERSION=8\necho pinned\n".utf8)
			let entry = try GuestSetupStore.current.add(
				custom, kind: GuestSetupStore.Kind.custom, vm: "pin")
			let detached = try #require(throws: MachmanError.self) {
				try vm.pinSetupScript(entry.id)
			}
			#expect(detached.code == .invalidState)
			#expect(detached.message == "Guest Setup isn’t attached to pin")
			try vm.addDevice(GuestDevice(kind: .guestSetup))
			let unknown = try #require(throws: MachmanError.self) {
				try vm.pinSetupScript("custom-000000000000")
			}
			#expect(unknown.code == .notFound)
			#expect(vm.setup?.script == nil)
			#expect(try VMConfig.load(name: "pin").setup?.script == nil)

			try vm.pinSetupScript(entry.id)
			#expect(try VMConfig.load(name: "pin").setup?.script == entry.id)
			// A stopped VM's share stays empty; its next served start carries the pin.
			let payload = GuestInstallerWriter.payloadDirectory(
				named: GuestSetupInstaller.directoryName, for: vm)
			#expect(!FileManager.default.fileExists(atPath: payload.path))
			let (served, _) = try GuestSetupInstaller.writePayload(for: vm)
			#expect(try Data(contentsOf: served.appendingPathComponent(
				GuestSetupInstaller.scriptName)) == custom)
		}
	}

	@Test("S67: an import refuses a folder, a binary file and one over 1 MB")
	func anImportTakesOneTextFile() throws {
		let dir = TestEnvironment.scratchURL.appendingPathComponent("import-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let store = GuestSetupStore(root: dir.appendingPathComponent("store"))
		func refusal(_ path: URL) throws -> String {
			try #require(throws: MachmanError.self) {
				try store.importScript(atPath: path.path, vm: "Debian")
			}.message
		}
		#expect(try refusal(dir) == "“\(dir.lastPathComponent)” isn’t a file")
		let binary = dir.appendingPathComponent("tool")
		try Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01]).write(to: binary)
		#expect(try refusal(binary) == "“tool” isn’t a text file")
		let big = dir.appendingPathComponent("big.sh")
		try Data(repeating: 0x23, count: GuestSetupStore.maxScriptBytes + 1).write(to: big)
		#expect(try refusal(big) == "“big.sh” is larger than 1 MB")
		#expect(store.entries().map(\.id) == [store.builtIn.entry.id])

		let patched = dir.appendingPathComponent("patched.sh")
		try Data("#!/bin/sh\nSCRIPT_VERSION=8\necho patched\n".utf8).write(to: patched)
		let entry = try store.importScript(atPath: patched.path, vm: "Debian")
		#expect(entry.kind == GuestSetupStore.Kind.custom && entry.id.hasPrefix("custom-"))
		#expect(entry.label == "patched.sh" && entry.vm == "Debian" && entry.version == 8)
		#expect(store.entry(id: entry.id) == entry)
	}
}
