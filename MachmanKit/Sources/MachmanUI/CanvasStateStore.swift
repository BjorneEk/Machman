//
//  CanvasStateStore.swift
//  MachmanUI
//
//  Client-side persistence of each VM's canvas layout (CanvasState), so a VM's tabs, panes
//  and divider positions are restored as they last appeared. Pure desktop concern — nothing
//  here touches the wire. Same pattern as TerminalProfileStore (PersistedJSONFile): a JSON
//  file in the suite-scoped app-support directory, written atomically off the main thread
//  with writes coalesced (a divider drag writes about twice a second, not per frame), read
//  tolerantly (one broken layout costs only that VM's) and set aside as a .bak, never
//  overwritten, when it can't be read at all; flush() writes what is pending (termination,
//  tests). The live terminal controllers behind the tabs stay in the app target
//  (TerminalSessions); this stores only the value layout. A layout outlives its VM's absence
//  from a list and goes with the VM itself — deleted here, or a new VM under its name, told
//  apart by the created date recorded beside it (T33, the port profiles' rule).
//

import Foundation
import MachmanAPI

@MainActor
public final class CanvasStateStore: ObservableObject {
	// Saved layouts by VM name. Only VMs whose canvas was ever changed have an entry.
	@Published public private(set) var canvases: [String: CanvasState]
	// Which VM each saved layout belongs to (a file from before learns it from a list).
	private var created: VMOwnerDates
	// The names the last landed list showed, kept across launches: a rename made elsewhere
	// is a name a list brings in place of one it drops (T34). nil until a list has landed
	// (a file from before T34).
	public private(set) var listedNames: Set<String>?

	private let file: PersistedJSONFile<PersistedState>

	// Default location: <app-support>/<suite>/CanvasLayouts.json. Injectable for tests.
	public nonisolated static func defaultURL() -> URL {
		URL(fileURLWithPath: MachmanPaths.defaultDataDir())
			.appendingPathComponent("CanvasLayouts.json")
	}

	// `saveDelay` is how long writes coalesce (tests shorten or stretch it).
	public init(
		fileURL: URL = CanvasStateStore.defaultURL(), saveDelay: Duration = .milliseconds(500)
	) {
		let file = PersistedJSONFile<PersistedState>(
			url: fileURL, label: "CanvasStateStore",
			queueLabel: "com.gustaffranzen.Machman.canvasLayouts.save", saveDelay: saveDelay)
		self.file = file
		let state = file.load()
		self.canvases = state?.canvases ?? [:]
		self.created = VMOwnerDates(state?.created ?? [:])
		self.listedNames = state?.listed.map(Set.init)
	}

	// The canvas to show for a VM — a fresh single-pane layout when none was saved.
	public func canvas(for vm: String) -> CanvasState {
		canvases[vm] ?? CanvasState()
	}

	// An unchanged layout (a click on the active tab, a tap on a strip) is no change: it
	// would republish every observer and queue a write for nothing (P36).
	public func setCanvas(_ canvas: CanvasState, for vm: String) {
		guard canvases[vm] != canvas else { return }
		canvases[vm] = canvas
		save()
	}

	// Drop tabs whose port no longer exists from a VM's saved layout; returns the removed
	// refs so the caller tears down their controllers (CanvasState.reconcile's contract).
	@discardableResult
	public func reconcile(vm: String, existing: Set<SerialPortRef>) -> [SerialPortRef] {
		guard var canvas = canvases[vm] else { return [] }
		let removed = canvas.reconcile(existing: existing)
		if !removed.isEmpty {
			canvases[vm] = canvas
			save()
		}
		return removed
	}

	// Migrate a VM's saved layout on rename, so its canvas survives it.
	public func renameVM(from old: String, to new: String) {
		guard let canvas = canvases.removeValue(forKey: old) else { return }
		canvases[new] = canvas
		created.move(from: old, to: new)
		save()
	}

	// MARK: - Internals

	private func save() {
		// Snapshot on the main actor (cheap value copy); the file encodes + writes off it.
		// SSH tabs are stripped: sessions are ephemeral, only layout persists.
		file.save(PersistedState(
			canvases: canvases.mapValues { $0.strippingEphemeralTabs() }, created: created.dates,
			listed: listedNames.map { $0.sorted() }))
	}

	private struct PersistedState: Codable, Sendable {
		var canvases: [String: CanvasState]
		// Each layout's VM by its created date (T33); an older file has none, and reads so.
		var created: [String: Date]
		// The last list's names (T34); absent in a file from before.
		var listed: [String]?

		init(canvases: [String: CanvasState], created: [String: Date], listed: [String]?) {
			self.canvases = canvases
			self.created = created
			self.listed = listed
		}

		// One VM's broken layout (or date) costs only itself.
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			canvases = c.decodeTolerantDictionary(of: CanvasState.self, forKey: .canvases)
			created = c.decodeTolerantDictionary(of: Date.self, forKey: .created)
			listed = try? c.decodeIfPresent([String].self, forKey: .listed)
		}
	}
}

// The layout is the run's: Save as New VM takes it to the saved VM, as a rename does — but
// the saved VM is a new one, so its date comes from the next list and the original's goes.
extension CanvasStateStore: VMKeyedState {
	public func copyVM(from old: String, to new: String) {
		guard let canvas = canvases.removeValue(forKey: old) else { return }
		canvases[new] = canvas
		created.forget(old)
		created.forget(new)
		save()
	}

	// Not on absence: a VM missing from one list (an external library asleep, a config that
	// briefly failed to load) finds its layout again when it is back (T33).
	public func forgetVMs(except kept: Set<String>) {}

	// Deleted here: its layout goes.
	public func vmDeleted(_ vm: String) {
		if drop(vm) { save() }
	}

	// A listed VM under a name with a layout: the one it belongs to, whose created date is
	// recorded the first time a list shows it — or a new VM, which starts on a fresh layout.
	// (A rename made elsewhere reaches here as renameVM first, from the view model, T34.)
	public func listed(_ vms: [VMInfo]) {
		let (stale, changed) = created.reconcile(vms, owners: Set(canvases.keys))
		for vm in stale { canvases[vm] = nil }
		let names = Set(vms.map(\.name))
		let moved = listedNames != names
		listedNames = names
		if changed || moved { save() }
	}

	public var ownerDates: [String: Date] { created.dates }

	// Forget `vm`'s layout and its date; true when there was something to forget.
	@discardableResult
	private func drop(_ vm: String) -> Bool {
		let hadCanvas = canvases.removeValue(forKey: vm) != nil
		return created.forget(vm) || hadCanvas
	}
}

extension CanvasStateStore: PersistedSettingsStore {
	public var settingsFile: (any PersistedFile)? { file }
	public static let settingsDescription = "tab layouts"
}
