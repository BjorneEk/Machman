//
//  PreviewService.swift
//  MachmanDesktop
//
//  App-scoped preview polling: one ~4s loop per visible running VM, writing frames into the
//  isolated PreviewStore (only the small PreviewView re-renders per frame — see PreviewStore).
//  Today the visible set is just the sidebar selection; the tabbed canvas widens it to every
//  VM tab on screen. Polls only while the window is focused, restarts a VM's loop on its
//  stateChanged (keyed off the event's state so a not-yet-patched row can't stall it), and
//  keeps the last frame across reconnects — DaemonConnection re-attaches it per connection.
//

import AppKit
import MachmanAPI

@MainActor
final class PreviewService: ObservableObject {
	// Views observe the store directly; the service itself publishes nothing per frame.
	let images = PreviewStore()
	private let store: VMStore
	private var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?
	private var tasks: [String: Task<Void, Never>] = [:]
	private var visible: Set<String> = []
	private var focused = true
	private let interval: Double = 4

	init(store: VMStore) {
		self.store = store
	}

	func attach(api: MachmanControlling) {
		detach()
		self.api = api
		eventTask = Task { [weak self] in
			let stream = await api.events()
			for await event in stream {
				guard let self else { return }
				if case .stateChanged(let name, let state) = event {
					self.restart(name, latestState: state)
				}
			}
		}
		// Revive the loops the last detach stopped (the visible set survives reconnects).
		restartAll()
	}

	func detach() {
		eventTask?.cancel()
		eventTask = nil
		api = nil
		restartAll()   // with no api every loop stops; images keep their last frame
	}

	// Which VMs' previews are on screen. Adding starts a loop, removing stops one; an
	// unchanged set is a no-op (running loops keep their cadence).
	func setVisible(_ names: Set<String>) {
		guard names != visible else { return }
		let stale = visible.subtracting(names)
		let added = names.subtracting(visible)
		visible = names
		for name in stale { restart(name) }
		for name in added { restart(name) }
	}

	func setFocused(_ focused: Bool) {
		guard focused != self.focused else { return }
		self.focused = focused
		restartAll()
	}

	// Keep the last frame under the new name so the preview doesn't blank on rename.
	func renameVM(from old: String, to new: String) {
		if let image = images.images.removeValue(forKey: old) {
			images.images[new] = image
		}
	}

	// Restart is the one entry point: cancel, then recreate only if the VM should be polled.
	private func restart(_ name: String, latestState: VMState? = nil) {
		tasks[name]?.cancel()
		tasks[name] = nil
		guard api != nil, focused, visible.contains(name) else { return }
		let state = latestState ?? store.vms.first { $0.name == name }?.state
		guard state?.isRunning == true else { return }
		tasks[name] = Task { [weak self] in
			while !Task.isCancelled {
				guard let self, let api = self.api, self.visible.contains(name) else { return }
				let data = try? await api.preview(vm: name, maxWidth: 1280)
				if Task.isCancelled { return }
				if let data = data, let image = NSImage(data: data) {
					self.images.images[name] = image
				}
				try? await Task.sleep(for: .seconds(self.interval))
			}
		}
	}

	private func restartAll() {
		for name in visible.union(tasks.keys) {
			restart(name)
		}
	}
}
