//
//  PreviewService.swift
//  MachmanDesktopCore
//
//  App-scoped preview polling: one ~4s loop per visible running VM, writing frames into the
//  isolated PreviewStore (only the small PreviewView re-renders per frame — see PreviewStore).
//  The visible set is the sidebar selection plus every VM with a torn-off Configuration window
//  (T18; read from TornTabRegistry). Polls only while the app is focused (active, with any of
//  its windows key — DaemonConnection's FocusMonitor says so), restarts a VM's loop on its
//  stateChanged (keyed off the event's state so a not-yet-patched row can't stall it), starts
//  a shown VM's loop when a list reload shows it running, and keeps the last frame across
//  reconnects — DaemonConnection re-attaches it per connection. A VM that leaves the list
//  takes its frame along (P40), so a new VM under its name never shows the old screen.
//  Frames decode off the main actor (Q5): only the finished image is handed to the store.
//

import AppKit
import Combine
import ImageIO
import MachmanAPI
import MachmanUI

@MainActor
public final class PreviewService: ObservableObject {
	// Turns a frame's bytes into an image, off the main actor.
	public typealias FrameDecoder = @Sendable (Data) async -> CGImage?

	// Views observe the store directly; the service itself publishes nothing per frame.
	public let images = PreviewStore()
	private let store: VMStore
	private var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?
	private var tasks: [String: Task<Void, Never>] = [:]
	private var visible: Set<String> = []
	// The two sources of `visible`: what the main window selects, and torn-off windows.
	private var selection: Set<String> = []
	private var torn: Set<String> = []
	private var tornSink: AnyCancellable?
	private var listSink: AnyCancellable?
	private var focused = true
	private let interval: Double = 4
	private let decode: FrameDecoder
	// Names a rename moved a frame to, kept until a list shows them: the rename's reply can
	// land before the list that carries the new name.
	private var renamedIn: Set<String> = []

	// `tornTabs`: the registry whose open Configuration windows also get frames; nil polls
	// the selection only. `decode`: tests see where frames decode.
	public init(
		store: VMStore, tornTabs: TornTabRegistry? = nil,
		decode: @escaping FrameDecoder = { await PreviewService.decodeFrame($0) }
	) {
		self.store = store
		self.decode = decode
		// $open emits the incoming set (willSet) — use it, never tornTabs.open here.
		tornSink = tornTabs?.$open.sink { [weak self] open in
			self?.setTorn(open)
		}
		// A reload can show a VM running that no stateChanged announced: a vmhost adopted
		// late, a list fetched after a reconnect, a selection the list itself made. $vms
		// emits on willSet and the selection may follow the same list, so look a turn later.
		listSink = store.$vms.receive(on: DispatchQueue.main).sink { [weak self] _ in
			self?.pruneFrames()
			self?.startMissedLoops()
		}
	}

	public func attach(api: MachmanControlling) {
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

	public func detach() {
		eventTask?.cancel()
		eventTask = nil
		api = nil
		restartAll()   // with no api every loop stops; images keep their last frame
	}

	// Which VMs the main window shows (its selection).
	public func setVisible(_ names: Set<String>) {
		selection = names
		apply()
	}

	private func setTorn(_ open: Set<TornTab>) {
		torn = Set(open.filter { $0.tab == .config }.map(\.vm))
		apply()
	}

	// Adding a VM starts its loop, removing one stops it; an unchanged set is a no-op
	// (running loops keep their cadence).
	private func apply() {
		let names = selection.union(torn)
		guard names != visible else { return }
		let stale = visible.subtracting(names)
		let added = names.subtracting(visible)
		visible = names
		for name in stale { restart(name) }
		for name in added { restart(name) }
	}

	// Test seam: the VMs with a polling loop right now.
	var pollingNames: Set<String> { Set(tasks.keys) }

	public func setFocused(_ focused: Bool) {
		guard focused != self.focused else { return }
		self.focused = focused
		restartAll()
	}

	// Keep the last frame under the new name so the preview doesn't blank on rename.
	public func renameVM(from old: String, to new: String) {
		if let image = images.images.removeValue(forKey: old) {
			images.images[new] = image
			renamedIn.insert(new)
		}
	}

	// Frames of VMs the list no longer holds go, and with them the NSImages they kept alive.
	private func pruneFrames() {
		let names = Set(store.vms.map(\.name))
		renamedIn.subtract(names)
		let gone = images.images.keys.filter { !names.contains($0) && !renamedIn.contains($0) }
		for name in gone {
			images.images[name] = nil
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
				if let data, let frame = await self.decode(data) {
					if Task.isCancelled { return }
					self.images.images[name] = NSImage(cgImage: frame, size: .zero)
				}
				try? await Task.sleep(for: .seconds(self.interval))
			}
		}
	}

	// Starts only: a stop comes as its own stateChanged, and a stale row must never cut a loop
	// a newer event started.
	private func startMissedLoops() {
		for name in visible where tasks[name] == nil {
			restart(name)
		}
	}

	// The whole decode happens here, cached at once, so drawing the frame later decodes
	// nothing on the main thread.
	public nonisolated static func decodeFrame(_ data: Data) async -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
		return CGImageSourceCreateImageAtIndex(source, 0, options)
	}

	private func restartAll() {
		for name in visible.union(tasks.keys) {
			restart(name)
		}
	}
}
