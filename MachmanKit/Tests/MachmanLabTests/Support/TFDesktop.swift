//
//  TFDesktop.swift
//  MachmanLabTests
//
//  The desktop's client stack over a lab agent, wired the way DaemonConnection.attach wires
//  the app's: VMStore and OperationsStore attached to their own connection, a VMListViewModel
//  over them. Never the stores' default files (they point at Application Support/<suite> of
//  this process): the canvas and profile stores live in the scope's desktop/ dir, the
//  activity list in memory. PreviewService is built and never attached (no preview polls).
//  Terminals default to a recorder that never opens a socket or a process.
//

import Combine
import Foundation
import MachmanAPI
import MachmanClient
import MachmanUI
@testable import MachmanDesktopCore

@MainActor
final class TFDesktop {
	let api: MachmanControlling
	let store = VMStore()
	let operations = OperationsStore()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	let terminals: TerminalSessions
	let viewModel: VMListViewModel
	let toasts: TFToastLog
	private let remote: RemoteMachman?

	init(api: MachmanControlling, dir: String, terminals: TerminalSessions? = nil) {
		self.api = api
		remote = api as? RemoteMachman
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let url = URL(fileURLWithPath: dir)
		canvases = CanvasStateStore(fileURL: url.appendingPathComponent("Canvas.json"))
		profiles = TerminalProfileStore(fileURL: url.appendingPathComponent("Profiles.json"))
		previews = PreviewService(store: store)
		self.terminals = terminals ?? TerminalSessions { TFNullTerminal(profile: $0) }
		store.attach(api: api)
		operations.attach(api: api)
		viewModel = VMListViewModel(
			api: api, store: store, operations: operations, terminals: self.terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
		toasts = TFToastLog(viewModel)
	}

	/// A stack on its own connection to `agent`, once the first list has landed.
	static func make(
		agent: LabAgent, terminals: TerminalSessions? = nil
	) async throws -> TFDesktop {
		let api = try await RemoteMachman(
			socketPath: agent.socketPath, clientName: "MachmanDesktop-lab")
		let dir = agent.scope.dir + "/desktop/" + UUID().uuidString
		let desktop = TFDesktop(api: api, dir: dir, terminals: terminals)
		try await desktop.waitForList()
		return desktop
	}

	func waitForList(timeout: Duration = .seconds(15)) async throws {
		let expected = try await api.listVMs().map(\.name)
		try await TFWait.until("the desktop's first list", timeout: timeout) {
			Set(self.store.vms.map(\.name)) == Set(expected)
		}
	}

	/// The store's entry for `name` once `match` holds — no reload asked for.
	@discardableResult
	func waitForEntry(
		_ name: String, _ what: String, timeout: Duration, _ match: (VMInfo) -> Bool
	) async throws -> VMInfo {
		var found: VMInfo?
		try await TFWait.until("the desktop list to show \(name) \(what)", timeout: timeout) {
			found = self.store.vms.first { $0.name == name }
			return found.map(match) ?? false
		}
		return found!
	}

	func close() async {
		store.detach()
		operations.detach()
		await remote?.disconnect()
	}
}

/// A terminal that records its lifecycle and never connects anything.
@MainActor
final class TFNullTerminal: TerminalController {
	private(set) var connected = false
	let startupSignature: TerminalStartupSignature
	private(set) var connectedPaths: [String] = []
	private(set) var disconnects = 0

	init(profile: TerminalProfile) { startupSignature = profile.startupSignature }

	func connect(path: String) {
		connectedPaths.append(path)
		connected = true
	}

	func connect(stream: TerminalByteStream) { connected = true }

	func disconnect() {
		disconnects += 1
		connected = false
	}

	func applyLive(_ profile: TerminalProfile) {}
	func note(_ text: String) {}
	func transcript() -> Data { Data() }
}

/// Every toast a view model shows, once: a new toast is a new entry, except a keyed slot
/// pushed again with the same message and spinner (one toast to the person watching).
@MainActor
final class TFToastLog {
	struct Entry: Equatable {
		let id: UUID
		let key: String?
		let message: String
		let spinner: Bool
	}

	private(set) var entries: [Entry] = []
	private var seen: Set<UUID> = []
	private var sink: AnyCancellable?

	init(_ viewModel: VMListViewModel) {
		record(viewModel.toasts)
		sink = viewModel.$toasts.sink { [weak self] toasts in
			MainActor.assumeIsolated { self?.record(toasts) }
		}
	}

	func record(_ toasts: [MachmanToast]) {
		for toast in toasts where !seen.contains(toast.id) {
			seen.insert(toast.id)
			if let key = toast.key, let last = entries.last(where: { $0.key == key }),
				last.message == toast.message, last.spinner == toast.spinner {
				continue
			}
			entries.append(Entry(
				id: toast.id, key: toast.key, message: toast.message, spinner: toast.spinner))
		}
	}

	var messages: [String] { entries.map(\.message) }

	func count(containing text: String) -> Int {
		entries.filter { $0.message.contains(text) }.count
	}

	func count(equal text: String) -> Int { entries.filter { $0.message == text }.count }

	/// Waits for a toast whose message contains `text`; returns its index in `entries`.
	@discardableResult
	func waitFor(_ text: String, timeout: Duration) async throws -> Int {
		var index: Int?
		try await TFWait.until("a toast containing “\(text)”", timeout: timeout) {
			index = self.entries.firstIndex { $0.message.contains(text) }
			return index != nil
		}
		return index!
	}
}
