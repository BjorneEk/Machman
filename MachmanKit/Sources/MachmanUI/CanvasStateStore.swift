//
//  CanvasStateStore.swift
//  MachmanUI
//
//  Client-side persistence of each VM's canvas layout (CanvasState), so a VM's tabs, panes
//  and divider positions are restored as they last appeared. Pure desktop concern — nothing
//  here touches the wire. Same pattern as TerminalProfileStore: a JSON file in the
//  suite-scoped app-support directory, written atomically off the main thread; flush()
//  waits for pending writes (termination, tests). The live terminal controllers behind the
//  tabs stay in the app target (TerminalSessions); this stores only the value layout.
//

import Foundation
import MachmanAPI

@MainActor
public final class CanvasStateStore: ObservableObject {
	// Saved layouts by VM name. Only VMs whose canvas was ever changed have an entry.
	@Published public private(set) var canvases: [String: CanvasState]

	private let fileURL: URL
	private let saveQueue = DispatchQueue(
		label: "com.gustaffranzen.Machman.canvasLayouts.save", qos: .utility)

	// Default location: <app-support>/<suite>/CanvasLayouts.json. Injectable for tests.
	public nonisolated static func defaultURL() -> URL {
		URL(fileURLWithPath: MachmanPaths.defaultDataDir())
			.appendingPathComponent("CanvasLayouts.json")
	}

	public init(fileURL: URL = CanvasStateStore.defaultURL()) {
		self.fileURL = fileURL
		if let data = try? Data(contentsOf: fileURL),
			let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
			self.canvases = state.canvases
		} else {
			self.canvases = [:]
		}
	}

	// The canvas to show for a VM — a fresh single-pane layout when none was saved.
	public func canvas(for vm: String) -> CanvasState {
		canvases[vm] ?? CanvasState()
	}

	public func setCanvas(_ canvas: CanvasState, for vm: String) {
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

	// Forget a deleted VM's layout.
	public func removeVM(_ vm: String) {
		guard canvases.removeValue(forKey: vm) != nil else { return }
		save()
	}

	// MARK: - Internals

	private func save() {
		// Snapshot on the main actor (cheap value copy), then encode + write off it.
		let snapshot = PersistedState(canvases: canvases)
		let url = fileURL
		saveQueue.async {
			do {
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
				let data = try encoder.encode(snapshot)
				try FileManager.default.createDirectory(
					at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				try data.write(to: url, options: .atomic)
			} catch {
				MachmanLogger.log(.passiveError, "CanvasStateStore save failed: \(error)")
			}
		}
	}

	// Block until pending writes have landed on disk (app termination and tests).
	public func flush() {
		saveQueue.sync {}
	}

	private struct PersistedState: Codable {
		var canvases: [String: CanvasState]
	}
}
