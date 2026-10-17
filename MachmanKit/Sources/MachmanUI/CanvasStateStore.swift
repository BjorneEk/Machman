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
//  (TerminalSessions); this stores only the value layout.
//

import Foundation
import MachmanAPI

@MainActor
public final class CanvasStateStore: ObservableObject {
	// Saved layouts by VM name. Only VMs whose canvas was ever changed have an entry.
	@Published public private(set) var canvases: [String: CanvasState]

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
		self.canvases = file.load()?.canvases ?? [:]
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
		save()
	}

	// MARK: - Internals

	private func save() {
		// Snapshot on the main actor (cheap value copy); the file encodes + writes off it.
		// SSH tabs are stripped: sessions are ephemeral, only layout persists.
		file.save(PersistedState(canvases: canvases.mapValues { $0.strippingEphemeralTabs() }))
	}

	private struct PersistedState: Codable, Sendable {
		var canvases: [String: CanvasState]

		init(canvases: [String: CanvasState]) {
			self.canvases = canvases
		}

		// One VM's broken layout costs only that layout.
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			canvases = c.decodeTolerantDictionary(of: CanvasState.self, forKey: .canvases)
		}
	}
}

// The layout is the run's: Save as New VM takes it to the saved VM, as a rename does.
extension CanvasStateStore: VMKeyedState {
	public func copyVM(from old: String, to new: String) {
		renameVM(from: old, to: new)
	}

	// Forget the layouts of deleted VMs.
	public func forgetVMs(except kept: Set<String>) {
		let gone = canvases.keys.filter { !kept.contains($0) }
		guard !gone.isEmpty else { return }
		for vm in gone { canvases[vm] = nil }
		save()
	}
}

extension CanvasStateStore: PersistedSettingsStore {
	public var settingsFile: (any PersistedFile)? { file }
	public static let settingsDescription = "tab layouts"
}
