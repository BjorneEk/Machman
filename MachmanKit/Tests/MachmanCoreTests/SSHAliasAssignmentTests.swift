//
//  SSHAliasAssignmentTests.swift
//  MachmanCoreTests
//
//  Two VM names that map to one default alias ("dev copy" and "dev-copy"), per the user's
//  rule (A-1a-1): the VM taking a name yields and stores a suffix, a stored alias never
//  moves because another VM changed, and VMs that already collide are split by a fixed
//  tie-break whose result is persisted on the loser's next save.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct SSHAliasAssignmentTests {

	@discardableResult
	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	// A config written as an older build would have: no alias assigned, nothing persisted.
	private func writeOlderVM(_ name: String, created: Date) throws {
		let template = try makeVM("template-\(UUID().uuidString)")
		defer { try? VMConfig.deleteVMDirectory(name: template.name) }
		template.created = created
		try VMConfig.createNewVMDirectory(name: name)
		try JSONEncoder().encode(template)
			.write(to: URL(fileURLWithPath: machmanVMDir + "/\(name)/config"))
	}

	private func alias(_ name: String) throws -> String {
		try VMConfig.load(name: name).effectiveSSHAlias
	}

	private func copy(_ source: String, to newName: String) throws {
		try VMCopier.copy(VMCopyRequest(
			sourceDir: machmanVMDir + "/" + source, destinationParent: machmanVMDir,
			newName: newName))
	}

	@Test func aDuplicateThatCollidesIsSuffixedAndStoresIt() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("dev")
			try makeVM("dev-copy")
			try copy("dev", to: "dev copy")

			let duplicate = try VMConfig.load(name: "dev copy")
			#expect(duplicate.ssh?.alias == "dev-copy-2.machman")
			#expect(duplicate.effectiveSSHAlias == "dev-copy-2.machman")
			// Stored, but not SSH set up here: nothing is served for it.
			#expect(duplicate.servedSSHState(installerAttached: false) == nil)
			#expect(duplicate.servedSSHState(installerAttached: true)?.alias
				== "dev-copy-2.machman")
			#expect(try alias("dev-copy") == "dev-copy.machman")
		}
	}

	// Daemon startup stores an older collision's suffix, so the winner's delete can't move it
	// even when the loser is never saved in between. A VM a live vmhost serves is its host's.
	@Test func daemonStartupStoresAnOlderCollisionsSuffix() throws {
		try VMTestDir.withRedirectedDir {
			let older = Date(timeIntervalSince1970: 1_600_000_000)
			try writeOlderVM("dev copy", created: older)
			try writeOlderVM("dev-copy", created: older.addingTimeInterval(1))
			try writeOlderVM("x y", created: older)
			try writeOlderVM("x  y", created: older.addingTimeInterval(1))
			let routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
			let hostedSocket = routing.hostSocketPath(for: "x  y")
			routing.storeCollisionAliases(isSocketLive: { $0 == hostedSocket })

			#expect(try VMConfig.load(name: "dev copy").ssh?.alias == "dev-copy-2.machman")
			#expect(try VMConfig.load(name: "dev-copy").ssh == nil)   // the winner follows its name
			#expect(try VMConfig.load(name: "x  y").ssh == nil)
			try VMConfig.deleteVMDirectory(name: "dev-copy")
			#expect(try alias("dev copy") == "dev-copy-2.machman")   // before: dev-copy.machman
		}
	}

	@Test func deletingTheOtherVMLeavesTheSuffix() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("dev")
			try makeVM("dev-copy")
			try copy("dev", to: "dev copy")
			try VMConfig.deleteVMDirectory(name: "dev-copy")
			#expect(try alias("dev copy") == "dev-copy-2.machman")
		}
	}

	@Test func renamingTheOtherVMLeavesTheSuffix() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("dev")
			let first = try makeVM("dev-copy")
			try copy("dev", to: "dev copy")
			try first.rename(to: "other")
			#expect(try alias("dev copy") == "dev-copy-2.machman")
			#expect(try alias("other") == "other.machman")
		}
	}

	// The VM taking the name yields — even to a name that needs mapping.
	@Test func aVMTakingANameYieldsToTheOneHoldingIt() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("dev copy")
			let created = try makeVM("dev-copy")
			#expect(created.ssh?.alias == "dev-copy-2.machman")
			#expect(try alias("dev copy") == "dev-copy.machman")

			let renamed = try makeVM("x")
			try renamed.rename(to: "dev  copy")
			#expect(renamed.effectiveSSHAlias == "dev-copy-3.machman")
			#expect(try alias("dev copy") == "dev-copy.machman")
			#expect(try alias("dev-copy") == "dev-copy-2.machman")
		}
	}

	@Test func saveAsNewVMYields() throws {
		try VMTestDir.withRedirectedDir {
			let library = machmanVMDir + "-lib"
			defer { try? FileManager.default.removeItem(atPath: library) }
			let shadow = try makeVM("alpha")
			try FileManager.default.createDirectory(
				atPath: library + "/dev-copy", withIntermediateDirectories: true)
			try JSONEncoder().encode(shadow)
				.write(to: URL(fileURLWithPath: library + "/dev-copy/config"))
			let registry = VMRegistry(only: "alpha", promotionLibrary: library)
			let vm = try #require(registry.vm(named: "alpha"))
			vm.runtime = VMRuntime(config: vm.config, events: registry.events)

			let promoted = try registry.promoteRestrictedVM(to: "dev copy")
			#expect(promoted.config.ssh?.alias == "dev-copy-2.machman")
		}
	}

	// A suffix stood in for the default: a new name gets its own. A chosen alias stays.
	@Test func aRenameDropsItsAssignedSuffixButKeepsAChosenAlias() throws {
		try VMTestDir.withRedirectedDir {
			try makeVM("dev-copy")
			let second = try makeVM("dev copy")
			#expect(second.ssh?.alias == "dev-copy-2.machman")
			try second.rename(to: "staging")
			#expect(second.ssh == nil)
			#expect(second.effectiveSSHAlias == "staging.machman")

			let chosen = try makeVM("chosen")
			try chosen.setSSH(integrationEnabled: nil, reverseApproved: nil, alias: "mine")
			try chosen.rename(to: "chosen 2")
			#expect(chosen.effectiveSSHAlias == "mine")
		}
	}

	@Test func olderCollisionsBreakTiesAndPersistOnTheNextSave() throws {
		try VMTestDir.withRedirectedDir {
			let older = Date(timeIntervalSince1970: 1_600_000_000)
			let newer = Date(timeIntervalSince1970: 1_700_000_000)
			// The name that needs no mapping keeps the base, even when it is newer…
			try writeOlderVM("dev copy", created: older)
			try writeOlderVM("dev-copy", created: newer)
			#expect(try alias("dev-copy") == "dev-copy.machman")
			#expect(try alias("dev copy") == "dev-copy-2.machman")
			// …otherwise the older VM keeps it…
			try writeOlderVM("x y", created: older)
			try writeOlderVM("x  y", created: newer)
			#expect(try alias("x y") == "x-y.machman")
			#expect(try alias("x  y") == "x-y-2.machman")
			// …then name order.
			try writeOlderVM("p q", created: older)
			try writeOlderVM("p  q", created: older)
			#expect(try alias("p  q") == "p-q.machman")
			#expect(try alias("p q") == "p-q-2.machman")

			// The loser's next save stores its suffix, so the winner going can't move it.
			let loser = try VMConfig.load(name: "dev copy")
			try loser.saveVMConfig()
			#expect(loser.ssh?.alias == "dev-copy-2.machman")
			try VMConfig.deleteVMDirectory(name: "dev-copy")
			#expect(try alias("dev copy") == "dev-copy-2.machman")
			// A winner's save stores nothing: it keeps following its name.
			let winner = try VMConfig.load(name: "x y")
			try winner.saveVMConfig()
			#expect(winner.ssh == nil)
		}
	}

	@Test func assignedSuffixesAreRecognized() {
		#expect(SSHAliasAssignment.isAssigned("dev-copy-2.machman", to: "dev copy"))
		#expect(SSHAliasAssignment.isAssigned("dev-copy-12.machman", to: "dev-copy"))
		for other in ["dev-copy.machman", "dev-copy-1.machman", "dev-copy-02.machman",
			"dev-copy-+3.machman", "other-2.machman", "dev-copy-2"] {
			#expect(!SSHAliasAssignment.isAssigned(other, to: "dev copy"), "\(other)")
		}
		#expect(SSHAliasAssignment.firstFree(
			"a.machman", taken: ["a.machman", "a-2.machman"]) == "a-3.machman")
	}
}
