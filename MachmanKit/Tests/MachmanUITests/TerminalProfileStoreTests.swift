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

	// MARK: - Unreadable values and files (P19)

	private static let customID = UUID(uuidString: "5A1E0000-0000-4000-8000-000000000001")!
	private let console = SerialPortRef(kind: .console, index: 0)

	private func write(_ json: String, to url: URL) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(json.utf8).write(to: url)
	}

	// A cursor style from a newer build costs that one field, never the file.
	@Test func anUnknownCursorKeepsEveryProfile() throws {
		let url = tempURL()
		let key = console.assocKey(vm: "vm1")
		try write("""
			{"profiles": [{"id": "\(Self.customID)", "name": "Big", "cursor": "blinkHollow",
			  "fontSize": 18}],
			 "associations": {"\(key)": "\(Self.customID)"}}
			""", to: url)
		let store = TerminalProfileStore(fileURL: url)
		let custom = try #require(store.profile(id: Self.customID))
		#expect(custom.name == "Big")
		#expect(custom.fontSize == 18)
		#expect(custom.cursor == .block)
		#expect(store.associatedID(vm: "vm1", ref: console) == Self.customID)
	}

	@Test func anUnreadableFileIsSetAside() throws {
		let url = tempURL()
		try write("not json", to: url)
		let store = TerminalProfileStore(fileURL: url)
		#expect(store.profiles.map(\.id) == [TerminalProfile.defaultID])
		store.flush()
		let backup = URL(fileURLWithPath: url.path + ".bak")
		#expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
		_ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
		// The one-time notice names the backup, once.
		let notice = store.takeSetAsideNotice()
		#expect(notice?.what == "terminal profiles")
		#expect(notice?.backup.path == backup.path)
		#expect(store.takeSetAsideNotice() == nil)
	}

	@Test func aReadableFileGivesNoNotice() {
		let store = TerminalProfileStore(fileURL: tempURL())
		#expect(store.takeSetAsideNotice() == nil)
	}

	@Test func aBadAssociationOrProfileCostsOnlyItself() throws {
		let url = tempURL()
		let key = console.assocKey(vm: "vm1")
		try write("""
			{"profiles": [42, {"id": "\(Self.customID)", "name": "Big"}],
			 "associations": {"\(key)": "\(Self.customID)", "vm2|uart|0": 42}}
			""", to: url)
		let store = TerminalProfileStore(fileURL: url)
		#expect(store.profile(id: Self.customID)?.name == "Big")
		#expect(store.associatedID(vm: "vm1", ref: console) == Self.customID)
	}

	@Test func missingColourKeysFallBackFieldByField() throws {
		let url = tempURL()
		try write("""
			{"profiles": [{"id": "\(Self.customID)", "name": "Mono",
			  "colors": {"foreground": "#ffffff", "ansi": ["#000000"]}}]}
			""", to: url)
		let store = TerminalProfileStore(fileURL: url)
		let colors = try #require(store.profile(id: Self.customID)).colors
		let oneDark = TerminalTheme.oneDark.colors
		#expect(colors.foreground == "#ffffff")
		#expect(colors.background == oneDark.background)
		#expect(colors.cursor == oneDark.cursor)
		#expect(colors.ansi == oneDark.ansi)   // not 16 entries: the preset's palette
	}
}
