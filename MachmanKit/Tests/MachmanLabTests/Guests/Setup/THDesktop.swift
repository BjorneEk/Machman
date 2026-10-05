//
//  THDesktop.swift
//  MachmanLabTests
//
//  The desktop's client stack on the lab agent, without a window: VMStore and OperationsStore
//  on a connection of their own, the persisted stores under the run's TH scratch, terminal
//  sessions whose controllers never connect, an unattached PreviewService (no polling) and a
//  VMListViewModel over them — r3-3a's view-model code as the app runs it, so the toasts a
//  person would see are the ones it pushes. Every toast that ever shows is recorded.
//

import Combine
import Foundation
import MachmanAPI
import MachmanClient
import MachmanUI
@testable import MachmanDesktopCore

/// A terminal controller that never connects (no tab is opened in these rows).
@MainActor
final class THNullTerminal: TerminalController {
	private(set) var connected = false
	let startupSignature: TerminalStartupSignature

	init(profile: TerminalProfile) { startupSignature = profile.startupSignature }

	func connect(path: String) {}
	func connect(stream: TerminalByteStream) {}
	func disconnect() {}
	func applyLive(_ profile: TerminalProfile) {}
	func note(_ text: String) {}
	func transcript() -> Data { Data() }
}

/// Every toast that ever showed, readable from any task.
final class THToastLog: @unchecked Sendable {
	private let lock = NSLock()
	private var seen: Set<UUID> = []
	private var messages: [String] = []

	func record(_ toasts: [MachmanToast]) {
		lock.withLock {
			for toast in toasts where !seen.contains(toast.id) {
				seen.insert(toast.id)
				messages.append(toast.message)
			}
		}
	}

	/// Every toast message shown so far, in order.
	var all: [String] { lock.withLock { messages } }

	/// How many toasts read exactly `message`.
	func count(_ message: String) -> Int { all.filter { $0 == message }.count }

	/// Waits until `message` has shown `count` times (false after `timeout`).
	func wait(for message: String, count wanted: Int, timeout: Duration = .seconds(60)) async
		-> Bool {
		let deadline = ContinuousClock.now + timeout
		while count(message) < wanted {
			if ContinuousClock.now >= deadline { return false }
			try? await Task.sleep(for: .milliseconds(250))
		}
		return true
	}
}

@MainActor
final class THDesktop {
	let api: RemoteMachman
	let store = VMStore()
	let operations = OperationsStore()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	let terminals: TerminalSessions
	let viewModel: VMListViewModel
	nonisolated let toasts = THToastLog()
	private var watch: AnyCancellable?

	private init(api: RemoteMachman, dir: String) {
		self.api = api
		let url = URL(fileURLWithPath: dir)
		canvases = CanvasStateStore(fileURL: url.appendingPathComponent("Canvas.json"))
		profiles = TerminalProfileStore(fileURL: url.appendingPathComponent("Profiles.json"))
		previews = PreviewService(store: store)
		terminals = TerminalSessions { profile in THNullTerminal(profile: profile) }
		store.attach(api: api)
		operations.attach(api: api)
		viewModel = VMListViewModel(
			api: api, store: store, operations: operations, terminals: terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
		let log = toasts
		watch = viewModel.$toasts.sink { log.record($0) }
	}

	/// The stack on a connection of its own to `agent`, its files under the scope's scratch.
	static func make(on agent: LabAgent) async throws -> THDesktop {
		let api = try await agent.connect(clientName: "machman-lab-th-desktop")
		let dir = try TH.hostDir(agent, "desktop")
		return THDesktop(api: api, dir: dir)
	}

	func close() async {
		watch = nil
		store.detach()
		await api.disconnect()
	}
}
