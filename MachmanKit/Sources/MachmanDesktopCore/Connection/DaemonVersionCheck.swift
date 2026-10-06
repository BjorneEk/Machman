//
//  DaemonVersionCheck.swift
//  MachmanDesktopCore
//
//  What the desktop decides about the Machman Agent it connected to (X7, E32, E45). The
//  desktop connects to whatever agent serves, so it is the process that can tell "this
//  agent is older than what I ship": one below the floor is offered for replacement (retire;
//  the connect loop then launches the embedded, current agent, which re-adopts the vmhosts),
//  or told to reinstall when this app embeds none. Not Now keeps it. An answer about an
//  agent that went meanwhile retires nothing — the one attached now is checked instead —
//  and an agent running work of its own refuses, which is said. The questions are seams:
//  DaemonConnection shows its alerts from a run-loop callout, tests answer them.
//

import Foundation
import MachmanAPI

@MainActor
public final class DaemonVersionCheck {
	public typealias Ask = @MainActor (DaemonVersionPrompt) async -> Bool
	public typealias Tell = @MainActor (DaemonVersionPrompt) async -> Void

	private let floor: String
	private let appVersion: String
	// Whether this app embeds an agent it can start in an old one's place.
	private let canReplace: @MainActor () -> Bool
	private let attached: @MainActor () -> (any DaemonSession)?
	// The too-old question: true for Replace.
	private let ask: Ask
	// An alert with only OK.
	private let tell: Tell
	// The question is up: a reconnect meanwhile is checked once it closes, never with a
	// second question on top of it.
	private var asking = false

	// `floor`: the oldest agent version this app works with; `attached`: the session
	// attached right now.
	public init(
		floor: String, appVersion: String, canReplace: @escaping @MainActor () -> Bool,
		attached: @escaping @MainActor () -> (any DaemonSession)?,
		ask: @escaping Ask, tell: @escaping Tell
	) {
		self.floor = floor
		self.appVersion = appVersion
		self.canReplace = canReplace
		self.attached = attached
		self.ask = ask
		self.tell = tell
	}

	public func check(_ session: any DaemonSession) async {
		guard !asking else { return }
		let running = session.daemonVersion
		guard MachmanVersion.isOlder(running, than: floor) else {
			if MachmanVersion.isOlder(appVersion, than: running) {
				// Reverse skew is tolerated by the additive-wire policy — log only.
				MachmanLogger.log(.log, "daemon \(running) is newer than this app (\(appVersion))")
			}
			return
		}
		let canReplace = canReplace()
		let prompt = DaemonVersionPrompt.tooOld(
			running: running, floor: floor, canReplace: canReplace)
		asking = true
		var replace = false
		if canReplace {
			replace = await ask(prompt)
		} else {
			await tell(prompt)
		}
		asking = false
		// The answer is about the agent the question named. While it showed, that one may
		// have gone and another attached (quit from its menu, the loop launched the current
		// one): never retire that one on a stale Replace — check whatever is attached now.
		guard attached() === session else {
			if let current = attached() { await check(current) }
			return
		}
		// Nothing newer to launch: the alert explained instead of offering a dead end.
		guard canReplace else { return }
		guard replace else {
			MachmanLogger.log(.passiveWarning,
				"daemon \(running) is below the floor \(floor); newer features may fail")
			return
		}
		// Retire drops the connection; the reconnect path launches the embedded agent. An
		// agent running work of its own refuses, and the alert says what (E45).
		do {
			try await session.api.retire()
		} catch let error as MachmanError where error.code == .invalidState {
			await tell(.replaceRefused(reason: error.message))
		} catch {
			// A dropped connection: the reconnect path takes it from here.
		}
	}
}
