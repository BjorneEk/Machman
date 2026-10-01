//
//  ConnectionLoop.swift
//  MachmanDesktopCore
//
//  The desktop's connect and reconnect state machine. A cycle makes at most `maxAttempts`
//  attempts and launches the agent at most once; it stops at once on an api mismatch and
//  after `maxNotAnswering` hello timeouts, then reports the problem so the connect screen
//  can offer Retry — never an endless "Connecting…" (P1). A session counts only once its
//  events subscription held, so the list never runs event-less (P13). An attempt whose cycle
//  was cancelled or replaced disconnects whatever it got and never attaches, and only the
//  attached session's drop starts a reconnect (P4). A session that keeps dying right after
//  connecting stops the loop after `maxQuickDrops`. Generic over DaemonSession, so all of it
//  runs headless against fakes; DaemonConnection is the thin app-side glue.
//

import Foundation
import MachmanAPI

// How hard one connect cycle tries before it stops and asks the user.
public struct ConnectionPolicy: Sendable {
	public var maxAttempts: Int
	public var retryDelay: Duration
	public var maxNotAnswering: Int
	public var maxQuickDrops: Int
	// A session that lived this long ended normally; a shorter one counts as a quick drop.
	public var healthySession: Duration

	public init(
		maxAttempts: Int = 20, retryDelay: Duration = .milliseconds(500),
		maxNotAnswering: Int = 2, maxQuickDrops: Int = 3,
		healthySession: Duration = .seconds(10)
	) {
		self.maxAttempts = maxAttempts
		self.retryDelay = retryDelay
		self.maxNotAnswering = maxNotAnswering
		self.maxQuickDrops = maxQuickDrops
		self.healthySession = healthySession
	}

	// Can't reach: 20 × 0.5 s (a cold agent's launch window). Silent: 2 hello timeouts.
	public static let standard = ConnectionPolicy()
}

@MainActor
public final class ConnectionLoop<Session: DaemonSession> {
	public typealias Policy = ConnectionPolicy

	public typealias Connect =
		@MainActor (_ onDrop: @escaping @Sendable () -> Void) async throws -> Session

	public private(set) var status: ConnectionStatus = .connecting

	private let policy: Policy
	private let connect: Connect
	private let launchDaemon: @MainActor () -> Void
	private let attach: @MainActor (Session) -> Void
	private let detach: @MainActor () -> Void
	private let onStatus: @MainActor (ConnectionStatus) -> Void

	private let clock = ContinuousClock()
	private let drops = DropLedger()
	private var cycleID = 0
	private var cycleTask: Task<Void, Never>?
	private var nextSessionID = 0
	// Attempts whose session is still being vetted: their drops wait in the ledger for them.
	private var resolving: Set<Int> = []
	private var current: (id: Int, session: Session, since: ContinuousClock.Instant)?
	private var quickDrops = 0

	public init(
		policy: Policy = .standard,
		connect: @escaping Connect,
		launchDaemon: @escaping @MainActor () -> Void,
		attach: @escaping @MainActor (Session) -> Void,
		detach: @escaping @MainActor () -> Void,
		onStatus: @escaping @MainActor (ConnectionStatus) -> Void
	) {
		self.policy = policy
		self.connect = connect
		self.launchDaemon = launchDaemon
		self.attach = attach
		self.detach = detach
		self.onStatus = onStatus
	}

	deinit {
		cycleTask?.cancel()
	}

	// Begin connecting, unless a cycle runs or a session is attached.
	public func start() {
		guard cycleTask == nil, current == nil else { return }
		startCycle(launched: false)
	}

	// The user's Retry: a fresh cycle with its counts reset. `launched` says the caller has
	// just launched the agent itself, so this cycle doesn't launch it again.
	public func retry(launched: Bool = false) {
		guard current == nil else { return }
		quickDrops = 0
		startCycle(launched: launched)
	}

	private func startCycle(launched: Bool) {
		cycleTask?.cancel()
		cycleID += 1
		let cycle = cycleID
		report(.connecting)
		cycleTask = Task { [weak self] in
			await self?.run(cycle: cycle, launched: launched)
		}
	}

	// A cancelled or replaced cycle touches nothing shared any more.
	private func isLive(_ cycle: Int) -> Bool {
		cycle == cycleID && !Task.isCancelled
	}

	private func run(cycle: Int, launched: Bool) async {
		var launched = launched
		var notAnswering = 0
		var last = ConnectionProblem(kind: .unreachable, detail: "no attempt was made")
		for attempt in 1...max(policy.maxAttempts, 1) {
			if attempt > 1 {
				try? await Task.sleep(for: policy.retryDelay)
			}
			guard isLive(cycle) else { return }
			let id = nextSessionID
			nextSessionID += 1
			resolving.insert(id)
			do {
				guard let session = try await open(id: id, cycle: cycle) else {
					resolving.remove(id)
					_ = drops.take(id)
					return
				}
				resolving.remove(id)
				// From the ledger check to attach nothing awaits, so a drop can't slip between.
				if drops.take(id) {
					await session.disconnect()
					throw ClosedWhileConnecting()
				}
				current = (id, session, clock.now)
				cycleTask = nil
				attach(session)
				report(.connected(daemonVersion: session.daemonVersion))
				return
			} catch {
				resolving.remove(id)
				_ = drops.take(id)
				guard isLive(cycle) else { return }
				last = ConnectionProblem.classify(error)
				switch last.kind {
				case .incompatible:
					finish(last)
					return
				case .notAnswering:
					notAnswering += 1
					if notAnswering >= policy.maxNotAnswering {
						finish(last)
						return
					}
				case .unreachable:
					if !launched {
						launched = true
						launchDaemon()
					}
				}
			}
		}
		guard isLive(cycle) else { return }
		finish(last)
	}

	// One attempt: connect, then confirm the events subscription. nil when the cycle ended
	// meanwhile — the session it got is disconnected, never attached (P4).
	private func open(id: Int, cycle: Int) async throws -> Session? {
		let drops = self.drops
		let session = try await connect { [weak self] in
			drops.record(id)
			Task { @MainActor [weak self] in
				self?.sessionDropped(id)
			}
		}
		guard isLive(cycle) else {
			await session.disconnect()
			return nil
		}
		do {
			try await session.subscribeEvents()
		} catch {
			await session.disconnect()
			throw error
		}
		guard isLive(cycle) else {
			await session.disconnect()
			return nil
		}
		return session
	}

	private func sessionDropped(_ id: Int) {
		guard let live = current, live.id == id else {
			// Never attached: an attempt still vetting it finds the ledger entry itself; a
			// stale, refused or abandoned session's drop is nobody's business (P1, P4).
			if !resolving.contains(id) {
				_ = drops.take(id)
			}
			return
		}
		_ = drops.take(id)
		current = nil
		quickDrops = clock.now - live.since < policy.healthySession ? quickDrops + 1 : 0
		detach()
		guard quickDrops < policy.maxQuickDrops else {
			finish(ConnectionProblem(
				kind: .unreachable,
				detail: "Machman Agent closed the connection right after connecting "
					+ "\(quickDrops) times"))
			return
		}
		startCycle(launched: false)
	}

	private func finish(_ problem: ConnectionProblem) {
		MachmanLogger.log(.passiveWarning, "stopped connecting to the agent: \(problem.detail)")
		cycleTask = nil
		report(.unavailable(problem))
	}

	private func report(_ status: ConnectionStatus) {
		self.status = status
		onStatus(status)
	}
}

// A session that died between its connect and its attach.
private struct ClosedWhileConnecting: Error, CustomStringConvertible {
	var description: String { "Machman Agent closed the connection while connecting" }
}

// Drops as sessions report them, recorded on the reporting thread: the attempt still vetting
// a session sees its drop before attaching it, whatever order the main-actor hops run in.
private final class DropLedger: @unchecked Sendable {
	private let lock = NSLock()
	private var ids: Set<Int> = []

	func record(_ id: Int) {
		lock.withLock { _ = ids.insert(id) }
	}

	func take(_ id: Int) -> Bool {
		lock.withLock { ids.remove(id) != nil }
	}
}
