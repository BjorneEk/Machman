//
//  DaemonVersionCheckTests.swift
//  MachmanDesktopCoreTests
//
//  The desktop's version check against the fake agent's socket, wired as DaemonConnection
//  wires it: the connect loop over the real RemoteMachman, each attached session checked.
//  These decisions lived in the app target, where only the lab's agent-side half of version
//  skew could be tested (Q20): the questions are answered here instead of shown.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: the version check on a scripted fake agent socket (no real agent, no alert).
@MainActor
struct DaemonVersionCheckTests {
	private static let floor = "1.0.12"
	private static let old = "1.0.11"
	private let retire = RPCMethod.daemonRetire.rawValue

	@Test("16b: a too-old agent is asked about as soon as it connects, and Replace retires it")
	func replaceRetiresTheOldAgent() async throws {
		let rig = try VersionRig()
		defer { rig.close() }
		rig.daemon.otherwise = .agent(version: Self.old, [.daemonRetire: .result("{}")])
		rig.loop.start()
		#expect(await rig.daemon.waitForRequest(retire))
		#expect(rig.asked == [DaemonVersionPrompt.tooOld(
			running: Self.old, floor: Self.floor, canReplace: true)])
		#expect(rig.told.isEmpty)
	}

	@Test("16b: a current agent is not asked about")
	func aCurrentAgentIsLeftAlone() async throws {
		let rig = try VersionRig()
		defer { rig.close() }
		rig.daemon.otherwise = .agent(version: Self.floor)
		rig.loop.start()
		#expect(await eventually { rig.checked == 1 })
		#expect(rig.asked.isEmpty && rig.told.isEmpty)
		#expect(!rig.daemon.requests.contains { $0.method == retire })
	}

	// E32: the question used to be a modal inside a main-actor job, which held every other
	// one — the list behind it froze.
	@Test("W4-21b: Not Now keeps the old agent, and its list updates while the question is open")
	func notNowKeepsTheAgent() async throws {
		let rig = try VersionRig()
		defer { rig.close() }
		let listed = Samples.linux("Debian", state: .running)
		rig.daemon.otherwise = .agent(version: Self.old, [.vmList: .json([listed])])
		let gate = ReplyGate()
		rig.answer = { _ in
			await gate.wait()
			return false
		}
		rig.loop.start()
		#expect(await eventually { rig.asked.count == 1 })
		let session = try #require(rig.current)
		let store = VMStore()
		store.attach(api: session)
		#expect(await eventually { store.vms.first?.state == .running })
		rig.daemon.send(.stateChanged(vm: "Debian", state: .stopped))
		#expect(await eventually { store.vms.first?.state == .stopped })
		gate.open()
		#expect(await eventually { rig.checked == 1 })
		#expect(!rig.daemon.requests.contains { $0.method == retire })
		#expect(rig.loop.status == .connected(daemonVersion: Self.old))
		store.detach()
	}

	@Test("W4-21b: an agent this app can't replace is told, not offered")
	func withoutAnEmbeddedAgentItTells() async throws {
		let rig = try VersionRig(canReplace: false)
		defer { rig.close() }
		rig.daemon.otherwise = .agent(version: Self.old)
		rig.loop.start()
		#expect(await eventually { rig.checked == 1 })
		#expect(rig.asked.isEmpty)
		#expect(rig.told == [DaemonVersionPrompt.tooOld(
			running: Self.old, floor: Self.floor, canReplace: false)])
		#expect(!rig.daemon.requests.contains { $0.method == retire })
	}

	@Test("R3W2-30: a Replace the agent refuses says why")
	func aRefusedReplaceSaysWhy() async throws {
		let rig = try VersionRig()
		defer { rig.close() }
		let reason = "dev is being copied \u{2014} try again when it finishes"
		rig.daemon.otherwise = .agent(version: Self.old, [
			.daemonRetire: .error(
				code: JSONRPC.applicationError, message: reason,
				dataJSON: #"{"machmanCode":"invalidState"}"#),
		])
		rig.loop.start()
		#expect(await eventually { rig.told.count == 1 })
		#expect(rig.told == [DaemonVersionPrompt.replaceRefused(reason: reason)])
		#expect(rig.told.first?.title == "Machman Agent can\u{2019}t be replaced yet")
	}

	// W4-28's desktop half: the old agent was quit while the question showed, and the loop
	// attached the current one.
	@Test("16b: a Replace answered after the agent changed retires nothing and checks the new one")
	func aStaleReplaceRetiresNothing() async throws {
		let rig = try VersionRig()
		defer { rig.close() }
		rig.daemon.scripts = [.agent(version: Self.old, [.daemonRetire: .result("{}")])]
		rig.daemon.otherwise = .agent(version: Self.floor, [.daemonRetire: .result("{}")])
		let gate = ReplyGate()
		rig.answer = { _ in
			await gate.wait()
			return true
		}
		rig.loop.start()
		#expect(await eventually { rig.asked.count == 1 })
		rig.daemon.dropAll()
		#expect(await eventually { rig.loop.status == .connected(daemonVersion: Self.floor) })
		gate.open()
		#expect(await eventually { rig.checked == 2 })
		#expect(!rig.daemon.requests.contains { $0.method == retire })
		#expect(rig.asked.count == 1)
	}
}

// The connect loop over the fake agent, checking each session it attaches the way
// DaemonConnection does, with the questions answered by the test.
@MainActor
final class VersionRig {
	let daemon: FakeDaemon
	private(set) var asked: [DaemonVersionPrompt] = []
	private(set) var told: [DaemonVersionPrompt] = []
	// Checks run to their end.
	private(set) var checked = 0
	var answer: @MainActor (DaemonVersionPrompt) async -> Bool = { _ in true }
	private(set) var current: RemoteMachman?
	private var sessions: [RemoteMachman] = []
	private(set) var loop: ConnectionLoop<RemoteMachman>!
	private var check: DaemonVersionCheck!

	init(canReplace: Bool = true) throws {
		daemon = try FakeDaemon()
		let daemon = self.daemon
		check = DaemonVersionCheck(
			floor: "1.0.12", appVersion: "1.0.12", canReplace: { canReplace },
			attached: { [weak self] in self?.current },
			ask: { [weak self] prompt in
				guard let self else { return false }
				asked.append(prompt)
				return await answer(prompt)
			},
			tell: { [weak self] prompt in self?.told.append(prompt) })
		loop = ConnectionLoop(
			policy: .fast(maxAttempts: 5),
			connect: { onDrop in try await daemon.remote(onDrop: onDrop) },
			launchDaemon: {},
			attach: { [weak self] session, _ in
				guard let self else { return }
				current = session
				sessions.append(session)
				let check = self.check
				Task { [weak self] in
					await check?.check(session)
					self?.checked += 1
				}
			},
			detach: { [weak self] in self?.current = nil },
			onStatus: { _ in })
	}

	func close() {
		daemon.close()
		let sessions = self.sessions
		Task {
			for session in sessions { await session.disconnect() }
		}
	}
}
