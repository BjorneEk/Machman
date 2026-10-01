//
//  TerminalProfileStore.swift
//  MachmanUI
//
//  Client-side store of terminal profiles and their per-socket associations. Rendering is purely a
//  desktop concern, so none of this touches the wire or the daemon: it persists to a JSON file in
//  the suite-scoped app-support directory (a dev build and a release build keep separate profiles).
//  Associations are keyed by a port's stable logical identity (vm|kind|index), never its ephemeral
//  socket path, so they survive VM stops and restarts.
//

import Foundation
import MachmanAPI

@MainActor
public final class TerminalProfileStore: ObservableObject {
	// All profiles, default first. Never empty (the default profile is always present).
	@Published public private(set) var profiles: [TerminalProfile]
	// assocKey ("vm|kind|index") → profile id. A missing / dangling entry falls back to default.
	@Published private var associations: [String: UUID]
	// Which profile the settings view is currently editing (drives its picker).
	@Published public var editingProfileID: UUID?

	// Persisted off the main thread, so a rapid edit stream (colour-picker drags, typing) never
	// blocks the UI on disk I/O; an unreadable file is set aside, never overwritten.
	private let file: PersistedJSONFile<PersistedState>
	private var setAsideNotice: SetAsideSettingsFile?

	// Default location: <app-support>/<suite>/TerminalProfiles.json. Injectable for tests.
	// nonisolated so it can be used as a default argument (evaluated off the main actor).
	public nonisolated static func defaultURL() -> URL {
		URL(fileURLWithPath: MachmanPaths.defaultDataDir())
			.appendingPathComponent("TerminalProfiles.json")
	}

	public init(fileURL: URL = TerminalProfileStore.defaultURL()) {
		let file = PersistedJSONFile<PersistedState>(
			url: fileURL, label: "TerminalProfileStore",
			queueLabel: "com.gustaffranzen.Machman.terminalProfiles.save")
		self.file = file
		let state = file.load()
		self.profiles = state?.profiles ?? []
		self.associations = state?.associations ?? [:]
		self.setAsideNotice = file.backupURL.map {
			SetAsideSettingsFile(what: "terminal profiles", backup: $0)
		}
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

	// Delete a profile; refuses the default and the last remaining one. Associations that pointed
	// at it are pruned, so those ports fall back to the default.
	public func delete(id: UUID) {
		guard id != defaultProfile.id, profiles.count > 1 else { return }
		profiles.removeAll { $0.id == id }
		associations = associations.filter { $0.value != id }
		if editingProfileID == id { editingProfileID = nil }
		save()
	}

	// Migrate a VM's association keys when it is renamed, so a port keeps its profile.
	public func renameVM(from old: String, to new: String) {
		let prefix = "\(old)|"
		var changed = false
		for (key, id) in associations where key.hasPrefix(prefix) {
			let suffix = key.dropFirst(prefix.count)
			associations["\(new)|\(suffix)"] = id
			associations[key] = nil
			changed = true
		}
		if changed { save() }
	}

	// MARK: - Internals

	private func ensureDefault() {
		if !profiles.contains(where: { $0.isDefault }) {
			profiles.insert(.oneDarkDefault, at: 0)
			save()
		}
	}

	private func uniqueName(basedOn base: String) -> String {
		let used = Set(profiles.map(\.name))
		if !used.contains(base) { return base }
		var n = 2
		while used.contains("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	private func save() {
		// Snapshot on the main actor (cheap value copy); the file encodes + writes off it.
		file.save(PersistedState(profiles: profiles, associations: associations))
	}

	// Block until pending writes have landed on disk (app termination and tests).
	public func flush() {
		file.flush()
	}

	private struct PersistedState: Codable, Sendable {
		var profiles: [TerminalProfile]
		var associations: [String: UUID]

		init(profiles: [TerminalProfile], associations: [String: UUID]) {
			self.profiles = profiles
			self.associations = associations
		}

		// One bad profile or association costs only itself.
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			profiles = c.decodeTolerantArray(of: TerminalProfile.self, forKey: .profiles)
			associations = c.decodeTolerantDictionary(of: UUID.self, forKey: .associations)
		}
	}
}

extension TerminalProfileStore: SetAsideReporting {
	public func takeSetAsideNotice() -> SetAsideSettingsFile? {
		defer { setAsideNotice = nil }
		return setAsideNotice
	}
}
