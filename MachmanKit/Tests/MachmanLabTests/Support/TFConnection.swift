//
//  TFConnection.swift
//  MachmanLabTests
//
//  The desktop's connect loop (ConnectionLoop, the policy the app uses) over the lab agent's
//  socket, with the app's glue as DaemonConnection does it: a fresh view model per session
//  that first announces what the last drop cut off. Records every status, launch and attach.
//  The launch is a closure: a test decides what "launching the agent" does (usually nothing,
//  or LabAgent.relaunch).
//

import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@MainActor
final class TFConnection {
	struct Attach {
		let version: String
		let interrupted: [InterruptedCall]
		let desktop: TFDesktop
	}

	/// DaemonConnection.helloDeadline (the app target's; not importable here).
	static let helloDeadline: Duration = .seconds(10)

	private(set) var statuses: [(status: ConnectionStatus, at: ContinuousClock.Instant)] = []
	private(set) var launches = 0
	private(set) var attaches: [Attach] = []
	private(set) var detaches = 0
	private(set) var loop: ConnectionLoop<RemoteMachman>?
	private let socketPath: String
	private let dir: String
	private let onLaunch: @MainActor () -> Void

	init(agent: LabAgent, onLaunch: @escaping @MainActor () -> Void = {}) {
		socketPath = agent.socketPath
		dir = agent.scope.dir + "/desktop/" + UUID().uuidString
		self.onLaunch = onLaunch
		loop = ConnectionLoop(
			policy: .standard,
			connect: { [socketPath] onDrop in
				try await RemoteMachman(
					socketPath: socketPath, clientName: "MachmanDesktop-lab",
					helloDeadline: Self.helloDeadline, onDisconnect: onDrop)
			},
			launchDaemon: { [weak self] in
				self?.launches += 1
				self?.onLaunch()
			},
			attach: { [weak self] session, interrupted in self?.attach(session, interrupted) },
			detach: { [weak self] in self?.detached() },
			onStatus: { [weak self] status in self?.statuses.append((status, .now)) })
	}

	private func attach(_ session: RemoteMachman, _ interrupted: [InterruptedCall]) {
		let desktop = TFDesktop(
			api: session, dir: dir + "/\(attaches.count)", terminals: nil)
		desktop.viewModel.announceInterrupted(interrupted)
		attaches.append(Attach(
			version: session.daemonVersion, interrupted: interrupted, desktop: desktop))
	}

	private func detached() {
		detaches += 1
		attaches.last?.desktop.store.detach()
		attaches.last?.desktop.operations.detach()
	}

	var status: ConnectionStatus { loop?.status ?? .connecting }

	func start() { loop?.start() }

	func retry() { loop?.retry() }

	/// The first status after `since` that matches `match`.
	@discardableResult
	func waitFor(
		_ what: String, since: ContinuousClock.Instant? = nil, timeout: Duration,
		_ match: @escaping (ConnectionStatus) -> Bool
	) async throws -> (status: ConnectionStatus, at: ContinuousClock.Instant) {
		var hit: (status: ConnectionStatus, at: ContinuousClock.Instant)?
		try await TFWait.until("the connect loop to report \(what)", timeout: timeout) {
			hit = self.statuses.first { (since == nil || $0.at >= since!) && match($0.status) }
			return hit != nil
		}
		return hit!
	}

	/// Drops the loop first (its cycle is cancelled; nothing reconnects), then every session.
	func close() async {
		loop = nil
		for attach in attaches { await attach.desktop.close() }
	}
}
