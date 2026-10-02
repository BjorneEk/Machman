import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

// Deleting a terminal profile asks first (H9): the trash button deleted a user-built palette
// at once, with no undo. The settings view's trash now requests the delete and its dialog
// confirms; the default and the last profile are never offered.
@MainActor
struct ProfileDeletionTests {
	private func store() -> TerminalProfileStore {
		TerminalProfileStore(fileURL: TestEnvironment.scratchURL
			.appendingPathComponent("pd-\(UUID().uuidString)")
			.appendingPathComponent("TerminalProfiles.json"))
	}

	@Test func deletingAsksFirst() {
		let store = store()
		let p = store.addProfile()
		store.requestDelete(id: p.id)
		#expect(store.profiles.contains { $0.id == p.id })
		#expect(store.pendingDeletion == p)
	}

	@Test func confirmingDeletesAndClears() {
		let store = store()
		let p = store.addProfile()
		let ref = SerialPortRef(kind: .console, index: 0)
		store.associate(vm: "Debian", ref: ref, to: p.id)
		store.requestDelete(id: p.id)
		store.delete(id: p.id)
		#expect(!store.profiles.contains { $0.id == p.id })
		#expect(store.pendingDeletion == nil)
		#expect(store.profile(vm: "Debian", ref: ref).id == store.defaultProfile.id)
	}

	@Test func theDefaultIsNeverOffered() {
		let store = store()
		store.addProfile()
		#expect(!store.canDelete(id: store.defaultProfile.id))
		store.requestDelete(id: store.defaultProfile.id)
		#expect(store.pendingDeletion == nil)
	}

	@Test func theLastProfileIsNeverOffered() {
		let store = store()
		#expect(store.profiles.count == 1)
		let only = store.profiles[0].id
		#expect(!store.canDelete(id: only))
		store.requestDelete(id: only)
		#expect(store.pendingDeletion == nil)
		#expect(store.profiles.count == 1)
	}
}
