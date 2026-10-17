//
//  TerminalProfileStore.swift
//  MachmanUI
//
//  Client-side store of terminal profiles and their per-socket associations. Rendering is purely a
//  desktop concern, so none of this touches the wire or the daemon: it persists to a JSON file in
//  the suite-scoped app-support directory (a dev build and a release build keep separate profiles).
//  Associations are keyed by a port's stable logical identity (vm|kind|index), never its ephemeral
//  socket path, so they survive VM stops and restarts; they follow their VM's name like the rest
//  of the client state (VMKeyedState, T29). They outlive a VM's absence from a list and go with
//  the VM itself: deleted here, or a new VM under its name — told apart by the created date
//  recorded beside them.
//

import Foundation
import MachmanAPI

@MainActor
public final class TerminalProfileStore: ObservableObject {
	// All profiles, default first. Never empty (the default profile is always present).
	@Published public private(set) var profiles: [TerminalProfile]
	// assocKey ("vm|kind|index") → profile id. A missing / dangling entry falls back to default.
	@Published private var associations: [String: UUID]
	// VM name → the created date of the VM its associations belong to, learned from the first
	// list that shows it (a file from before has none until then).
	private var created: VMOwnerDates
	// Which profile the settings view is currently editing (drives its picker).
	@Published public var editingProfileID: UUID?
	// The profile whose delete waits for confirmation (H9; the settings view asks). UI state,
	// never persisted.
	@Published public var pendingDeletion: TerminalProfile?

	// Persisted off the main thread with writes coalesced, so a rapid edit stream (colour-picker
	// drags, typing) neither blocks the UI nor writes per change; flush() writes what is
	// pending. An unreadable file is set aside, never overwritten.
	private let file: PersistedJSONFile<PersistedState>

	// Default location: <app-support>/<suite>/TerminalProfiles.json. Injectable for tests.
	// nonisolated so it can be used as a default argument (evaluated off the main actor).
	public nonisolated static func defaultURL() -> URL {
		URL(fileURLWithPath: MachmanPaths.defaultDataDir())
			.appendingPathComponent("TerminalProfiles.json")
	}

	// `saveDelay` is how long writes coalesce (tests shorten or stretch it).
	public init(
		fileURL: URL = TerminalProfileStore.defaultURL(), saveDelay: Duration = .milliseconds(500)
	) {
		let file = PersistedJSONFile<PersistedState>(
			url: fileURL, label: "TerminalProfileStore",
			queueLabel: "com.gustaffranzen.Machman.terminalProfiles.save", saveDelay: saveDelay)
		self.file = file
		let state = file.load()
		self.profiles = state?.profiles ?? []
		self.associations = state?.associations ?? [:]
		self.created = VMOwnerDates(state?.created ?? [:])
		ensureDefault()
	}

	// MARK: - Resolution

	// The profile associated with a port, or the default when unassociated / dangling.
	public func profile(vm: String, ref: SerialPortRef) -> TerminalProfile {
		if let id = associations[ref.assocKey(vm: vm)],
			let p = profiles.first(where: { $0.id == id }) {
			return p
		}
		return defaultProfile
	}

	public var defaultProfile: TerminalProfile {
		profiles.first(where: { $0.isDefault }) ?? profiles.first ?? .oneDarkDefault
	}

	public func profile(id: UUID) -> TerminalProfile? {
		profiles.first(where: { $0.id == id })
	}

	// The id the picker should show for a port (an explicit association, else the default's id).
	public func associatedID(vm: String, ref: SerialPortRef) -> UUID {
		associations[ref.assocKey(vm: vm)] ?? defaultProfile.id
	}

	// MARK: - Associations

	public func associate(vm: String, ref: SerialPortRef, to id: UUID?) {
		let key = ref.assocKey(vm: vm)
		if let id, id != defaultProfile.id {
			associations[key] = id
		} else {
			associations[key] = nil   // default is the implicit fallback; store nothing
		}
		save()
	}

	// MARK: - Mutations

	@discardableResult
	public func addProfile() -> TerminalProfile {
		var p = defaultProfile
		p.id = UUID()
		p.name = uniqueName(basedOn: "New Profile")
		profiles.append(p)
		save()
		return p
	}

	public func update(_ profile: TerminalProfile) {
		guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
		profiles[i] = profile
		save()
	}

	// Copy an existing profile into a new one (a fresh id + unique name). Falls back to a plain
	// add if the source is gone.
	@discardableResult
	public func duplicate(id: UUID) -> TerminalProfile {
		guard var p = profiles.first(where: { $0.id == id }) else { return addProfile() }
		p.id = UUID()
		p.name = uniqueName(basedOn: p.name + " copy")
		profiles.append(p)
		save()
		return p
	}

	// The default and the last remaining profile can't be deleted.
	public func canDelete(id: UUID) -> Bool {
		id != defaultProfile.id && profiles.count > 1
	}

	// Ask before deleting (H9): a user-built profile is gone for good once deleted.
	public func requestDelete(id: UUID) {
		guard canDelete(id: id), let p = profile(id: id) else { return }
		pendingDeletion = p
	}

	// Delete a profile; refuses the default and the last remaining one. Associations that pointed
	// at it are pruned, so those ports fall back to the default.
	public func delete(id: UUID) {
		if pendingDeletion?.id == id { pendingDeletion = nil }
		guard canDelete(id: id) else { return }
		profiles.removeAll { $0.id == id }
		associations = associations.filter { $0.value != id }
		if editingProfileID == id { editingProfileID = nil }
		save()
	}

	// MARK: - Internals

	private func ensureDefault() {
		if !profiles.contains(where: { $0.isDefault }) {
			profiles.insert(.oneDarkDefault, at: 0)
			save()
		}
	}

	// The VM an association key belongs to: everything before its last two fields (kind and
	// index), since a VM name may itself hold "|".
	private static func vm(ofKey key: String) -> Substring? {
		guard let indexField = key.lastIndex(of: "|"),
			let kindField = key[..<indexField].lastIndex(of: "|") else { return nil }
		return key[..<kindField]
	}

	// `old`'s associations under `new` too, in place of any `new` had; `move` drops them from
	// `old`, and its created date goes along. A copy is a new VM: the next list says its date.
	private func associate(_ old: String, as new: String, move: Bool) {
		let changed = drop(new)
		var moved = false
		for (key, id) in associations where Self.vm(ofKey: key) == old[...] {
			associations[new + key.dropFirst(old.count)] = id
			if move { associations[key] = nil }
			moved = true
		}
		if move { created.move(from: old, to: new) }
		if changed || moved { save() }
	}

	public var ownerDates: [String: Date] { created.dates }

	// The VM names holding associations.
	private var owners: Set<String> {
		Set(associations.keys.compactMap { Self.vm(ofKey: $0).map(String.init) })
	}

	// Forget `vm`'s associations and its date; true when there was something to forget.
	@discardableResult
	private func drop(_ vm: String) -> Bool {
		let kept = associations.filter { key, _ in Self.vm(ofKey: key) != vm[...] }
		let hadAssociations = kept.count != associations.count
		if hadAssociations { associations = kept }
		return created.forget(vm) || hadAssociations
	}

	private func uniqueName(basedOn base: String) -> String {
		let used = Set(profiles.map(\.name))
		return UniqueName.numbered(base, isTaken: used.contains)
	}

	private func save() {
		// Snapshot on the main actor (cheap value copy); the file encodes + writes off it.
		file.save(PersistedState(
			profiles: profiles, associations: associations, created: created.dates))
	}

	private struct PersistedState: Codable, Sendable {
		var profiles: [TerminalProfile]
		var associations: [String: UUID]
		// Each VM's created date (T29); an older file has none, and reads with none.
		var created: [String: Date]

		init(profiles: [TerminalProfile], associations: [String: UUID], created: [String: Date]) {
			self.profiles = profiles
			self.associations = associations
			self.created = created
		}

		// One bad profile, association or date costs only itself.
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			profiles = c.decodeTolerantArray(of: TerminalProfile.self, forKey: .profiles)
			associations = c.decodeTolerantDictionary(of: UUID.self, forKey: .associations)
			created = c.decodeTolerantDictionary(of: Date.self, forKey: .created)
		}
	}
}

extension TerminalProfileStore: VMKeyedState {
	// A renamed VM's ports keep their profiles.
	public func renameVM(from old: String, to new: String) {
		associate(old, as: new, move: true)
	}

	// Save as New VM: the saved VM's ports keep the run's profiles, and so do the original's.
	public func copyVM(from old: String, to new: String) {
		associate(old, as: new, move: false)
	}

	// Not on absence: a VM missing from one list (an external library asleep, a config that
	// briefly failed to load) finds its port profiles again when it is back (T29).
	public func forgetVMs(except kept: Set<String>) {}

	// Deleted here: its ports forget theirs.
	public func vmDeleted(_ vm: String) {
		if drop(vm) { save() }
	}

	// A VM of a name with associations: the one they belong to, whose created date is
	// recorded the first time a list shows it — or a new VM under that name, which starts on
	// the default (T29). (A rename made elsewhere reaches here as renameVM first, T34.)
	public func listed(_ vms: [VMInfo]) {
		let (stale, changed) = created.reconcile(vms, owners: owners)
		for vm in stale { drop(vm) }
		if changed { save() }
	}
}

extension TerminalProfileStore: PersistedSettingsStore {
	public var settingsFile: (any PersistedFile)? { file }
	public static let settingsDescription = "terminal profiles"
}
