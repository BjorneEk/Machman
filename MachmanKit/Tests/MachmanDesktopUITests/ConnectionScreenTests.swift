//
//  ConnectionScreenTests.swift
//  MachmanDesktopUITests
//
//  The connect screen end to end, short of the app target: the real connect loop over the
//  real client against the fake agent's socket stops on a problem, and ConnectionStatusView
//  hosted offscreen shows what that problem offers — Retry for a hung agent (launching a
//  second one would only concede to it), Launch Machman Agent as well when none is there.
//

import Foundation
import SwiftUI
import Testing
import MachmanAPI
import MachmanClient
import MachmanTestSupport
import MachmanDesktopCore
import MachmanDesktopUI

// L1: the connect loop over a fake agent socket, its screen hosted offscreen.
@MainActor
struct ConnectionScreenTests {
	@Test("W2-27a: a stalled agent's screen offers Retry and no Launch Machman Agent")
	func stalledAgentOffersRetryOnly() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .silent
		let status = await Self.stoppedStatus(daemon, helloDeadline: .seconds(2))
		guard case .unavailable(let problem) = status, problem.kind == .notAnswering else {
			Issue.record("the loop stopped on \(status)")
			return
		}
		let screen = try await Self.screen(status)
		#expect(screen.find(text: "Machman Agent is not answering") != nil)
		let hint = try #require(problem.hint)
		#expect(screen.find(text: hint) != nil)
		let retry = try #require(screen.find(role: "AXButton", text: "Retry"))
		#expect(retry.isEnabled)
		#expect(screen.find(text: "Launch Machman Agent") == nil)
	}

	@Test("P1: an agent that isn't there gets Launch Machman Agent and Retry")
	func missingAgentOffersLaunchAndRetry() async throws {
		let daemon = try FakeDaemon(listening: false)
		defer { daemon.close() }
		let status = await Self.stoppedStatus(daemon, helloDeadline: .seconds(10))
		guard case .unavailable(let problem) = status, problem.kind == .unreachable else {
			Issue.record("the loop stopped on \(status)")
			return
		}
		let screen = try await Self.screen(status)
		#expect(screen.find(text: "Can\u{2019}t reach Machman Agent") != nil)
		#expect(screen.find(text: "It isn\u{2019}t running.") != nil)
		for title in ["Launch Machman Agent", "Retry"] {
			let button = try #require(screen.find(role: "AXButton", text: title), "no \(title)")
			#expect(button.isEnabled)
		}
	}

	// Run the app's connect loop (its launch does nothing) against `daemon` until it stops.
	private static func stoppedStatus(
		_ daemon: FakeDaemon, helloDeadline: Duration
	) async -> ConnectionStatus {
		var sessions: [RemoteMachman] = []
		let loop = ConnectionLoop<RemoteMachman>(
			policy: ConnectionPolicy(maxAttempts: 5, retryDelay: .milliseconds(1)),
			connect: { try await daemon.remote(helloDeadline: helloDeadline, onDrop: $0) },
			launchDaemon: {},
			attach: { session, _ in sessions.append(session) },
			detach: {},
			onStatus: { _ in })
		loop.start()
		_ = await eventually(timeout: .seconds(30)) {
			if case .unavailable = loop.status { return true }
			return false
		}
		for session in sessions { await session.disconnect() }
		return loop.status
	}

	private static func screen(_ status: ConnectionStatus) async throws -> AXSnapshot {
		try await OffscreenHost.withHost(ConnectionStatusView(
			status: status, loginItemNeedsApproval: false,
			retry: {}, launchDaemon: {}, openLoginItems: {})) { $0.snapshot() }
	}
}
