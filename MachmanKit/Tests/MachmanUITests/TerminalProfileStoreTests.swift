import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

@MainActor
struct TerminalProfileStoreTests {
	private func tempURL() -> URL {
		TestEnvironment.scratchURL
			.appendingPathComponent("tps-\(UUID().uuidString)")
			.appendingPathComponent("TerminalProfiles.json")
	}

	@Test func seedsDefaultOnFirstRun() {
		let store = TerminalProfileStore(fileURL: tempURL())
		#expect(store.profiles.count == 1)
		#expect(store.defaultProfile.name == "OneDark")
		#expect(store.defaultProfile.isDefault)
	}

	@Test func unassociatedPortResolvesToDefault() {
		let store = TerminalProfileStore(fileURL: tempURL())
		let ref = SerialPortRef(kind: .console, index: 0)
		#expect(store.profile(vm: "vm1", ref: ref).id == store.defaultProfile.id)
	}

	@Test func associateThenResolveReturnsSpecificProfile() {
		let store = TerminalProfileStore(fileURL: tempURL())
		let p = store.addProfile()
		let ref = SerialPortRef(kind: .uart, index: 1)
		store.associate(vm: "vm1", ref: ref, to: p.id)
		#expect(store.profile(vm: "vm1", ref: ref).id == p.id)
		#expect(store.associatedID(vm: "vm1", ref: ref) == p.id)
	}

	@Test func persistsAndReloads() {
		let url = tempURL()
		let id: UUID
		do {
			let store = TerminalProfileStore(fileURL: url)
			var p = store.addProfile()
			id = p.id
			p.fontSize = 20
			p.name = "Big"
			store.update(p)
			store.associate(vm: "vm1", ref: SerialPortRef(kind: .console, index: 0), to: id)
			store.flush()   // writes are off-main now; wait for them before reloading
		}
		let reloaded = TerminalProfileStore(fileURL: url)
		#expect(reloaded.profiles.contains {
			$0.id == id && $0.name == "Big" && $0.fontSize == 20
		})
		#expect(reloaded.profile(
			vm: "vm1", ref: SerialPortRef(kind: .console, index: 0)).id == id)
	}

	@Test func duplicateCreatesIndependentCopy() {
		let store = TerminalProfileStore(fileURL: tempURL())
		var p = store.addProfile()
		p.name = "Base"
		p.fontSize = 18
		store.update(p)
		let copy = store.duplicate(id: p.id)
		#expect(copy.id != p.id)
		#expect(copy.fontSize == 18)          // carried the source's settings
		#expect(copy.name != p.name)          // uniquified
		#expect(store.profiles.contains { $0.id == copy.id })
	}

	@Test func deleteRefusesDefaultAndPrunesAssociations() {
		let store = TerminalProfileStore(fileURL: tempURL())
		store.delete(id: store.defaultProfile.id)
		#expect(store.profiles.count == 1)   // default survived

		let p = store.addProfile()
		let ref = SerialPortRef(kind: .console, index: 0)
		store.associate(vm: "vm1", ref: ref, to: p.id)
		store.delete(id: p.id)
		#expect(!store.profiles.contains { $0.id == p.id })
		#expect(store.profile(vm: "vm1", ref: ref).id == store.defaultProfile.id)   // fell back
	}

	@Test func renameVMMigratesAssociations() {
		let store = TerminalProfileStore(fileURL: tempURL())
		let p = store.addProfile()
		let ref = SerialPortRef(kind: .uart, index: 0)
		store.associate(vm: "old", ref: ref, to: p.id)
		store.renameVM(from: "old", to: "new")
		#expect(store.profile(vm: "new", ref: ref).id == p.id)
		#expect(store.profile(vm: "old", ref: ref).id == store.defaultProfile.id)
	}
}
