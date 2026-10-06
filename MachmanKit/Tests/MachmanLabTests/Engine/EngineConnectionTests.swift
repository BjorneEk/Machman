//
//  EngineConnectionTests.swift
//  MachmanLabTests
//
//  L2 — the desktop's ConnectionLoop over the real lab agent: a frozen agent (SIGSTOP) and
//  an agent killed in the middle of a start, as the app's connect screen and its next view
//  model see them. The connect-screen layout itself is L1 (W2-27a, W2-28a: r3-ta).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — connection loop", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineConnectionTests {
	@Test(
		"""
		W2-27: a stopped agent reads not answering within about 20 s, and Retry connects \
		once it runs
		""")
	func stoppedAgentReadsNotAnswering() async throws {
		try await Lab.withAgent { agent in
			let connection = TFConnection(agent: agent)
			try #require(TFProcess.stop(agent.pid))
			var stopped = true
			defer { if stopped { TFProcess.resume(agent.pid) } }
			let began = ContinuousClock.now
			connection.start()
			let hit = try await connection.waitFor("unavailable", timeout: .seconds(40)) {
				if case .unavailable = $0 { return true }
				return false
			}
			guard case .unavailable(let problem) = hit.status else { return }
			#expect(problem.kind == .notAnswering)
			#expect(problem.title == "Machman Agent is not answering")
			#expect(problem.hint
				== "Choose Quit Machman Agent from its menu-bar item, then click Retry.")
			// Two hellos of 10 s each: not before 15 s, and well before the minute a plain
			// RPC deadline would take.
			let elapsed = hit.at - began
			#expect(elapsed >= .seconds(15))
			#expect(elapsed <= .seconds(30))
			#expect(connection.launches == 0)   // a frozen agent is never launched again
			#expect(connection.attaches.isEmpty)
			TFProcess.resume(agent.pid)
			stopped = false
			let since = ContinuousClock.now
			connection.retry()
			let back = try await connection.waitFor(
				"connected", since: since, timeout: .seconds(20)
			) {
				if case .connected = $0 { return true }
				return false
			}
			#expect(back.status == .connected(daemonVersion: agent.bundleVersion))
			#expect(connection.attaches.count == 1)
			await connection.close()
		}
	}

	@Test("W2-28: an agent killed mid-start yields one connection-lost alert naming the start")
	func killedMidStartAlertsOnce() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(
				LabVMSpec(name: "killed-mid-start", boot: .alpine()), start: false
			) { _ in
				var relaunch: Task<Void, Error>?
				let connection = TFConnection(agent: agent) {
					// The app's "launch the agent": this scope's agent, once per drop.
					guard relaunch == nil else { return }
					relaunch = Task { try await agent.relaunch() }
				}
				defer { Task { await connection.close() } }
				connection.start()
				try await connection.waitFor("connected", timeout: .seconds(20)) {
					if case .connected = $0 { return true }
					return false
				}
				let socket = MachmanPaths.vmSocketPath(vm: "killed-mid-start")
				var caught: TFConnection.Attach?
				for attempt in 1...3 {
					let before = connection.attaches.count
					let desktop = try #require(connection.attaches.last).desktop
					desktop.viewModel.startVM("killed-mid-start", headless: true)
					// The kill lands while the start is in flight: as the vmhost's socket
					// appears, or 300 ms in.
					let sent = ContinuousClock.now
					while !FileManager.default.fileExists(atPath: socket),
						ContinuousClock.now - sent < .milliseconds(300) {
						try await Task.sleep(for: .milliseconds(10))
					}
					agent.kill(SIGKILL)
					try await TFWait.until("the next attach", timeout: .seconds(40)) {
						connection.attaches.count > before
					}
					try await relaunch?.value
					relaunch = nil
					let next = connection.attaches[before]
					if next.interrupted.contains(
						where: { $0.method == .start && $0.vm == "killed-mid-start" }
					) {
						caught = next
						break
					}
					// The start answered before the kill: stop the VM and try again.
					MachmanLogger.log(
						.passiveWarning, "lab: attempt \(attempt): the start finished first")
					_ = try? await TFVM.recordHost(agent, "killed-mid-start")
					await TFVM.forceStop(agent, "killed-mid-start")
				}
				guard let caught else {
					throw TFError.inconclusive(
						"three starts finished before the agent was killed; kill earlier")
				}
				let view = caught.desktop.viewModel
				try await TFWait.until("the connection-lost alert", timeout: .seconds(10)) {
					view.presentedError != nil
				}
				#expect(view.presentedError?.title == VMListViewModel.connectionLostTitle)
				#expect(
					view.presentedError?.message
						== "Check whether starting killed-mid-start finished.")
				view.isErrorPresented = false
				try await Task.sleep(for: .seconds(1))
				#expect(view.presentedError == nil)   // exactly one
				// The vmhost the killed agent spawned is the new agent's now (or gone).
				_ = try? await TFVM.recordHost(agent, "killed-mid-start")
				await TFVM.forceStop(agent, "killed-mid-start")
				await connection.close()
			}
		}
	}
}
