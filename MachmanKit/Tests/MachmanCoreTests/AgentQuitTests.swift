//
//  AgentQuitTests.swift
//  MachmanTests
//
//  V7 (the user's answer U1): with VMs running, a log out, restart or shut down used to meet
//  the agent's own quit prompt, behind other windows, whose choices quit the agent while every
//  VM's vmhost still cancelled the log out. Now the agent cancels its quit quietly and keeps
//  running (each VM's own prompt says what to do), quits when nothing runs, and asks only
//  when the user quits it. What counts as running: a VM its host last reported running, or a
//  start in flight; an idle host never holds a log out up.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct AgentQuitDecisionTests {
	private let sessionEnds: [VMHostQuitReason] = [.logOut, .restart, .shutDown]

	@Test func nothingRunningQuits() {
		for reason in sessionEnds + [.userQuit] {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 0) == .quit)
		}
	}

	@Test func aSessionEndCancelsQuietlyWhileVMsRun() {
		for reason in sessionEnds {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 1) == .cancelQuietly)
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 3) == .cancelQuietly)
		}
	}

	@Test func theUsersOwnQuitAsks() {
		#expect(AgentQuitDecision.decide(reason: .userQuit, runningVMs: 2) == .ask)
	}

	// The VM's own prompt is what explains a canceled log out now: US spelling (A-all-2).
	@Test func theVMsPromptSaysCanceled() {
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .logOut).info
			== "Log out was canceled: shut the VM down, then log out again.")
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .restart).info
			== "Restart was canceled: shut the VM down, then restart again.")
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .shutDown).info
			== "Shut down was canceled: shut the VM down, then shut down your Mac again.")
	}
}

struct RoutingRunningVMTests {
	@MainActor
	private func makeRouting() throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		routing.helloDeadline = .seconds(10)
		routing.hostProbeDeadline = .seconds(10)
		return routing
	}

	// A host serving alpha in `state`, adopted the way a late host is: by the next list.
	@MainActor
	private func adopt(_ routing: RoutingMachman, state: VMState) async throws
		-> (StubMachman, MachmanServer) {
		let socketPath = TestEnvironment.socketPath("mm-run")
		routing.socketPathForVM = { $0 == "alpha" ? socketPath : socketPath + ".none" }
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: state)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		_ = try await routing.listVMs()
		#expect(await eventually { routing.hostedNames == ["alpha"] })
		return (stub, server)
	}

	@Test @MainActor func aRunningHostedVMCounts() async throws {
		let routing = try makeRouting()
		let (stub, server) = try await adopt(routing, state: .running)
		defer { server.stop() }
		#expect(routing.runningVMNames == ["alpha"])

		// The host says its VM stopped: it no longer holds a log out up. Emitted once the
		// router's subscription reached the stub, so the event has somewhere to go.
		#expect(await eventually { stub.calls.contains("events") })
		stub.emit(.stateChanged(vm: "alpha", state: .stopped))
		#expect(await eventually { routing.runningVMNames.isEmpty })
	}

	@Test @MainActor func anIdleHostDoesNotCount() async throws {
		let routing = try makeRouting()
		let (_, server) = try await adopt(routing, state: .stopped)
		defer { server.stop() }
		#expect(routing.hostedNames == ["alpha"])
		#expect(routing.runningVMNames.isEmpty)
	}

	@Test @MainActor func aStartInFlightCounts() throws {
		let routing = try makeRouting()
		routing.reserveStart("beta", mac: nil)
		#expect(routing.runningVMNames == ["beta"])
	}
}

// X7: the agent's replace prompt ran three sentences and called the old agent "daemon".
struct AgentPromptTests {
	@Test func theReplacePromptIsOneSentence() throws {
		let prompt = AgentPrompt.replaceOlder(running: "1.0.11", mine: "1.0.12")
		#expect(prompt.message == "An older Machman Agent is still running")
		#expect(prompt.info == "Replacing version 1.0.11 with 1.0.12 keeps its VMs running.")
		#expect(prompt.buttons == ["Replace", "Cancel"])
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		#expect(prompt.info.matches(of: sentenceEnd).count == 1)
		#expect(!prompt.info.lowercased().contains("daemon"))
	}
}
