//
//  ActivityLog.swift
//  MachmanDesktopCore
//
//  The activity list (PR5, decision 13): what finished, failed or warned, kept after the
//  corner's toasts and cards are gone — finished operations, the engine's warnings and
//  errors, and the desktop's own problem toasts. The 50 newest entries, newest first;
//  warnings and failures stay unseen (the toolbar's badge) until the list is opened. Entries
//  are history: deleting a VM keeps its entries. App-scoped (OperationsStore owns it), so a
//  reconnect keeps it, and saved like the other settings files (PersistedJSONFile: writes
//  coalesce, flush() on quit, an unreadable file set aside as .bak and announced once,
//  tolerant decoding), so a relaunch keeps it too. The app passes defaultURL(); without a
//  file (tests, renders) the list lives in memory.
//

import Foundation
import MachmanAPI
import MachmanUI

public struct ActivityEntry: Identifiable, Equatable, Sendable, Codable {
	public enum Severity: String, Codable, Sendable {
		case done, info, warning, failure
	}

	public let id: UUID
	// The same thing again: recording an entry with a known key replaces the older one.
	public var key: String?
	public var date: Date
	public var vm: String?
	public var title: String
	public var detail: String?
	public var symbol: String
	public var severity: Severity

	public init(
		id: UUID = UUID(), key: String? = nil, date: Date, vm: String? = nil, title: String,
		detail: String? = nil, symbol: String, severity: Severity
	) {
		self.id = id
		self.key = key
		self.date = date
		self.vm = vm
		self.title = title
		self.detail = detail
		self.symbol = symbol
		self.severity = severity
	}

	// What the badge counts.
	public var isProblem: Bool { severity == .warning || severity == .failure }

	// A finished operation, once per operation.
	public static func operation(_ op: OperationInfo, at date: Date) -> ActivityEntry {
		let severity: Severity
		switch op.state {
		case OperationInfo.State.succeeded: severity = .done
		case OperationInfo.State.failed: severity = .failure
		default: severity = .info
		}
		return ActivityEntry(
			key: operationKey(op.id), date: date, vm: op.vm, title: op.displayTitle,
			detail: op.outcomeText, symbol: op.displaySymbol, severity: severity)
	}

	// An engine warning or error, keyed like its toast: a repeat moves it to the top.
	@MainActor
	public static func engineLog(
		vm: String?, level: LogLevel, message: String, at date: Date
	) -> ActivityEntry {
		let text = VMListViewModel.engineLogText(vm: vm, message: message)
		return ActivityEntry(
			key: VMListViewModel.logToastKey(text), date: date, vm: vm,
			title: vm ?? "Machman", detail: message, symbol: MachmanSymbols.warning,
			severity: level == .error ? .failure : .warning)
	}

	// One of the desktop's own problem toasts (a VM in error, a setup run that wasn't ok…).
	public static func problem(
		vm: String?, detail: String, symbol: String, severity: Severity, at date: Date
	) -> ActivityEntry {
		ActivityEntry(
			date: date, vm: vm, title: vm ?? "Machman", detail: detail, symbol: symbol,
			severity: severity)
	}

	public static func operationKey(_ id: String) -> String { "op:" + id }

	// Tolerant: a field another build wrote differently falls back; only an entry without
	// an id, date or title is dropped (by the list's tolerant decode).
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		date = try c.decode(Date.self, forKey: .date)
		title = try c.decode(String.self, forKey: .title)
		key = c.decodeTolerant(String.self, forKey: .key)
		vm = c.decodeTolerant(String.self, forKey: .vm)
		detail = c.decodeTolerant(String.self, forKey: .detail)
		symbol = c.decodeTolerant(String.self, forKey: .symbol) ?? MachmanSymbols.info
		severity = c.decodeTolerant(Severity.self, forKey: .severity) ?? .info
	}
}

@MainActor
public final class ActivityLog: ObservableObject {
	public static let capacity = 50

	@Published public private(set) var entries: [ActivityEntry] = []   // newest first
	@Published public private(set) var unseen: Set<UUID> = []

	private let file: PersistedJSONFile<PersistedState>?
	private var setAsideNotice: SetAsideSettingsFile?

	// <app-support>/<suite>/Activity.json, beside the other per-suite settings files.
	public nonisolated static func defaultURL() -> URL {
		URL(fileURLWithPath: MachmanPaths.defaultDataDir())
			.appendingPathComponent("Activity.json")
	}

	// `fileURL` nil keeps the list in memory; `saveDelay` is how long writes coalesce.
	public init(fileURL: URL? = nil, saveDelay: Duration = .milliseconds(500)) {
		let file = fileURL.map {
			PersistedJSONFile<PersistedState>(
				url: $0, label: "ActivityLog",
				queueLabel: "com.gustaffranzen.Machman.activity.save", saveDelay: saveDelay)
		}
		self.file = file
		if let stored = file?.load() {
			// Another build may have kept more, or in another order: the newest 50 count.
			entries = Array(stored.entries.sorted { $0.date > $1.date }.prefix(Self.capacity))
			unseen = Set(stored.unseen).intersection(entries.map(\.id))
		}
		setAsideNotice = file?.backupURL.map {
			SetAsideSettingsFile(what: "activity list", backup: $0)
		}
	}

	public var unseenProblems: Int { unseen.count }

	public func contains(key: String) -> Bool {
		entries.contains { $0.key == key }
	}

	public func record(_ entry: ActivityEntry) {
		if let key = entry.key, let old = entries.firstIndex(where: { $0.key == key }) {
			unseen.remove(entries.remove(at: old).id)
		}
		entries.insert(entry, at: 0)
		if entry.isProblem { unseen.insert(entry.id) }
		while entries.count > Self.capacity {
			unseen.remove(entries.removeLast().id)
		}
		save()
	}

	public func dismiss(id: UUID) {
		guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
		entries.remove(at: index)
		unseen.remove(id)
		save()
	}

	public func clearAll() {
		guard !entries.isEmpty else { return }
		entries = []
		unseen = []
		save()
	}

	// The list was opened: nothing in it is news any more.
	public func markSeen() {
		guard !unseen.isEmpty else { return }
		unseen = []
		save()
	}

	// Block until pending writes have landed on disk (app termination and tests).
	public func flush() {
		file?.flush()
	}

	private func save() {
		file?.save(PersistedState(entries: entries, unseen: Array(unseen)))
	}

	struct PersistedState: Codable, Sendable {
		var entries: [ActivityEntry]
		var unseen: [UUID]

		init(entries: [ActivityEntry], unseen: [UUID]) {
			self.entries = entries
			self.unseen = unseen
		}

		// One unreadable entry costs only that entry.
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			entries = c.decodeTolerantArray(of: ActivityEntry.self, forKey: .entries)
			unseen = c.decodeTolerantArray(of: UUID.self, forKey: .unseen)
		}
	}
}

extension ActivityLog: SetAsideReporting {
	public func takeSetAsideNotice() -> SetAsideSettingsFile? {
		defer { setAsideNotice = nil }
		return setAsideNotice
	}
}
