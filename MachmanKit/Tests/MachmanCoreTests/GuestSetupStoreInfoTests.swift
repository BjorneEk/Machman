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
}
