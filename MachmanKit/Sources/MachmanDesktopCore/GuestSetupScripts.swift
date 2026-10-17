//
//  GuestSetupScripts.swift
//  MachmanDesktopCore
//
//  The Guest Setup inspector's two version rows as rules (S67): Installed — the stored script
//  the guest's last report matched, its reported version when it matched none, with the
//  run's outcome — and Serves, the menu over the host's store of scripts: newest build first
//  with the latest marked, then the custom and changed ones, each dated with its VM. An older
//  Machman Agent sends no store, and Serves has no menu then.
//

import Foundation
import MachmanAPI

public enum GuestSetupScripts {
	// One item of the Serves menu.
	public struct Choice: Equatable, Identifiable, Sendable {
		public let id: String
		public let title: String
		public let isServed: Bool
	}

	// MARK: - Installed

	public static func installed(_ setup: GuestSetupInfo?) -> String {
		guard let setup, setup.installed == true else { return "Not installed" }
		// A build's script by its version; an imported or changed one is Custom.
		let script = installedEntry(setup).flatMap {
			$0.kind == GuestSetupScriptKind.build ? $0.version.map { "v\($0)" } : "Custom"
		} ?? setup.scriptVersion.map { "v\($0)" }
		switch setup.lastRunStatus {
		case GuestRunStatus.partial?:
			return "\(script ?? "Installed"), with gaps"
		case GuestRunStatus.failed?:
			return script.map { "\($0), last run failed" } ?? "Last run failed"
		default:
			return script ?? "Installed"
		}
	}

	// The stored script the guest's report named, when the store holds it.
	public static func installedEntry(_ setup: GuestSetupInfo?) -> GuestSetupScriptInfo? {
		guard let id = setup?.installedScript else { return nil }
		return setup?.scripts?.first { $0.id == id }
	}

	// MARK: - Serves

	// The menu's own title: what the VM serves, short enough for the narrowest inspector — a
	// custom script by its file name alone. nil from an older Machman Agent.
	public static func serves(_ setup: GuestSetupInfo?) -> String? {
		guard setup?.scripts != nil, let entry = servedEntry(setup) else { return nil }
		if entry.kind == GuestSetupScriptKind.custom, let label = entry.label {
			return "\u{201C}\(label)\u{201D}"
		}
		return shortTitle(entry)
	}

	public static func servedEntry(_ setup: GuestSetupInfo?) -> GuestSetupScriptInfo? {
		let scripts = setup?.scripts ?? []
		return scripts.first { $0.id == setup?.servedScript }
			?? scripts.first { $0.latest == true }
	}

	// The menu's items, newest build first, then the custom and changed scripts newest first.
	public static func choices(_ setup: GuestSetupInfo?) -> [Choice] {
		let scripts = setup?.scripts ?? []
		let served = servedEntry(setup)?.id
		return ordered(scripts).map {
			Choice(id: $0.id, title: menuTitle($0, among: scripts), isServed: $0.id == served)
		}
	}

	static func ordered(_ scripts: [GuestSetupScriptInfo]) -> [GuestSetupScriptInfo] {
		let builds = scripts.filter { $0.kind == GuestSetupScriptKind.build }
			.sorted { a, b in
				if (a.version ?? 0) != (b.version ?? 0) {
					return (a.version ?? 0) > (b.version ?? 0)
				}
				if (a.latest == true) != (b.latest == true) { return a.latest == true }
				return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast)
			}
		let others = scripts.filter { $0.kind != GuestSetupScriptKind.build }
			.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
		return builds + others
	}

	// "v8", "v8 — latest"; "Custom “patched.sh”", "Changed on Debian".
	static func shortTitle(_ entry: GuestSetupScriptInfo) -> String {
		switch entry.kind {
		case GuestSetupScriptKind.build:
			let version = entry.version.map { "v\($0)" } ?? "Machman’s script"
			return entry.latest == true ? "\(version) — latest" : version
		case GuestSetupScriptKind.changed:
			return entry.vm.map { "Changed on \($0)" } ?? "Changed"
		default:
			return entry.label.map { "Custom \u{201C}\($0)\u{201D}" } ?? "Custom"
		}
	}

	// The short title, then for a custom or changed script its VM and when it was stored —
	// and for an earlier build of a version listed twice, its date.
	static func menuTitle(_ entry: GuestSetupScriptInfo, among scripts: [GuestSetupScriptInfo])
		-> String {
		let title = shortTitle(entry)
		let stored = entry.addedAt?.formatted(date: .abbreviated, time: .shortened)
		switch entry.kind {
		case GuestSetupScriptKind.build:
			let twins = scripts.filter {
				$0.kind == GuestSetupScriptKind.build && $0.version == entry.version
			}
			guard twins.count > 1, entry.latest != true,
				let day = entry.addedAt?.formatted(date: .abbreviated, time: .omitted)
			else { return title }
			return "\(title) — \(day)"
		case GuestSetupScriptKind.changed:
			return stored.map { "\(title) — \($0)" } ?? title
		default:
			let place = [entry.vm, stored].compactMap { $0 }.joined(separator: ", ")
			return place.isEmpty ? title : "\(title) — \(place)"
		}
	}
}
