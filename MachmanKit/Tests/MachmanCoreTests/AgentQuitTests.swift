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
	private let running = SessionHolder(
		vm: "alpha", activity: "is still running", promptsItself: true)
	private let starting = SessionHolder(
		vm: "beta", activity: "is still starting", promptsItself: false)

	@Test func nothingRunningQuits() {
		for reason in sessionEnds + [.userQuit] {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 0, holders: []) == .quit)
		}
	}

	@Test func aSessionEndCancelsQuietlyWhileVMsRun() {
		for reason in sessionEnds {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 1, holders: [running])
				== .cancelQuietly)
		}
	}

	// V10: a start in flight or a vmhost that doesn't answer has no window to say why the log
	// out stopped — the agent cancelled it with only a log line. It says so itself now.
	@Test func aSessionEndExplainsWhatNoVMWindowWill() {
		for reason in sessionEnds {
			#expect(AgentQuitDecision.decide(
				reason: reason, runningVMs: 2, holders: [running, starting])
				== .cancelAndExplain([starting]))
		}
	}

	@Test func theUsersOwnQuitAsks() {
		#expect(AgentQuitDecision.decide(reason: .userQuit, runningVMs: 2, holders: [running])
			== .ask)
	}

	// E47: with no VM running, the user's own quit stopped a copy or an install without a
	// word. It asks now; a session end cancels and says what runs (C13).
	@Test func workTheAgentRunsHoldsAQuit() {
		let copying = SessionHolder(vm: "gamma", activity: "is being copied", promptsItself: false)
		#expect(AgentQuitDecision.decide(reason: .userQuit, runningVMs: 0, holders: [copying])
			== .askAboutWork([copying]))
		for reason in sessionEnds {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 0, holders: [copying])
				== .cancelAndExplain([copying]))
		}
		let one = AgentPrompt.quitDuringWork([copying])
		#expect(one.message == "gamma is being copied \u{2014} quit anyway?")
		#expect(one.info == "Quitting Machman Agent now stops it.")
		#expect(one.buttons == ["Cancel", "Quit Anyway"])   // the default keeps it
		let two = AgentPrompt.quitDuringWork([copying, copying])
		#expect(two.message == "2 VMs are busy \u{2014} quit anyway?")
		#expect(two.info == "Quitting Machman Agent now stops them.")
	}

	@Test func theAgentsAlertIsOneSentence() throws {
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		let one = AgentPrompt.sessionEndHeld(reason: .logOut, holders: [starting])
		#expect(one.message == "beta is still starting")
		#expect(one.info
			== "Log out was canceled: wait for it or stop it in Machman, then log out again.")
		#expect(one.buttons == ["OK"])
		let both = AgentPrompt.sessionEndHeld(reason: .restart, holders: [starting, starting])
		#expect(both.message == "2 VMs are busy")
		#expect(both.info
			== "Restart was canceled: wait for them or stop them in Machman, then restart again.")
		let off = AgentPrompt.sessionEndHeld(reason: .shutDown, holders: [starting])
		#expect(off.info == "Shut down was canceled: wait for it or stop it in Machman, then "
			+ "shut down your Mac again.")
		for prompt in [one, both, off] {
			#expect(prompt.info.matches(of: sentenceEnd).count == 1)
			#expect(!prompt.info.lowercased().contains("daemon"))
		}
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
	// `stalled`: it never answers vm.get (until the test lifts it), so the adoption's first
	// ask runs out its deadline.
	@MainActor
	private func adopt(_ routing: RoutingMachman, state: VMState, stalled: Bool = false)
		async throws -> (StubMachman, MachmanServer) {
		let socketPath = TestEnvironment.socketPath("mm-run")
		routing.socketPathForVM = { $0 == "alpha" ? socketPath : socketPath + ".none" }
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: state)
		if stalled { stub.stalled = ["vm"] }
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

	// An adoption whose first ask stalled has no state yet: unknown, never stopped, so it
	// holds a log out up until its host answers (O-2: it counted as stopped until a probe).
	@Test @MainActor func aHostThatNeverAnsweredCounts() async throws {
		let routing = try makeRouting()
		routing.hostProbeDeadline = .seconds(1)   // the stalled ask runs it out
		let (stub, server) = try await adopt(routing, state: .stopped, stalled: true)
		defer {
			stub.stalled = []
			server.stop()
		}
		#expect(routing.hostForTesting("alpha")?.lastState == nil)
		#expect(routing.runningVMNames == ["alpha"])
	}

	// A host that stops answering counts, whatever it said last.
	@Test @MainActor func anUnresponsiveHostCounts() async throws {
		let routing = try makeRouting()
		let (stub, server) = try await adopt(routing, state: .stopped)
		defer {
			stub.stalled = []
			server.stop()
		}
		#expect(routing.runningVMNames.isEmpty)
		routing.hostProbeDeadline = .seconds(1)   // the stalled ask runs it out
		stub.stalled = ["vm"]
		_ = try await routing.listVMs()
		#expect(routing.hostForTesting("alpha")?.unresponsive == true)
		#expect(routing.runningVMNames == ["alpha"])
	}

	@Test @MainActor func aStartInFlightCounts() throws {
		let routing = try makeRouting()
		routing.reserveStart("beta", mac: nil)
		#expect(routing.runningVMNames == ["beta"])
		// …and no vmhost window says so: the agent does (V10).
		#expect(routing.sessionHolders == [
			SessionHolder(vm: "beta", activity: "is still starting", promptsItself: false),
		])
	}

	// C13: work the agent runs itself dies with it, so it holds a log out too — one entry per
	// VM, however many copies run into it.
	@Test @MainActor func theAgentsOwnWorkHoldsALogOut() throws {
		let routing = try makeRouting()
		routing.claims.insert("alpha", .importingDisk)
		routing.claims.insert("alpha", .promotingDisk)
		routing.claims.insert("beta", .copying)
		routing.claims.insert("gamma", .importingDisk, inDaemon: false)   // its vmhost's
		#expect(routing.runningVMNames.isEmpty)
		#expect(routing.sessionHolders == [
			SessionHolder(vm: "alpha", activity: "is importing a disk", promptsItself: false),
			SessionHolder(vm: "beta", activity: "is being copied", promptsItself: false),
		])
	}

	@Test @MainActor func aMacOSInstallHoldsALogOut() throws {
		var finish: (() -> Void)?
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2).saveVMConfig()
			let registry = VMRegistry()
			var open = false
			registry.installRunner = { _, _ in
				while !open { try await Task.sleep(for: .milliseconds(10)) }
				throw CocoaError(.userCancelled)
			}
			finish = { open = true }
			let routing = RoutingMachman(registry: registry, daemonVersion: "test")
			try registry.installSession(for: #require(registry.vm(named: "mac")))
				.startInstall(source: InstallSource(kind: .ipsw, path: "/nonexistent.ipsw"))
			#expect(routing.sessionHolders == [
				SessionHolder(vm: "mac", activity: "is installing macOS", promptsItself: false),
			])
		}
		finish?()
	}

	// V10: only a vmhost running its VM and answering cancels a log out in front itself.
	@Test @MainActor func onlyARunningAnsweringHostPromptsItself() async throws {
		let routing = try makeRouting()
		let (stub, server) = try await adopt(routing, state: .running)
		defer {
			stub.stalled = []
			server.stop()
		}
		#expect(routing.sessionHolders == [
			SessionHolder(vm: "alpha", activity: "is still running", promptsItself: true),
		])

		routing.hostProbeDeadline = .seconds(1)   // the stalled ask runs it out
		stub.stalled = ["vm"]
		_ = try await routing.listVMs()
		#expect(routing.sessionHolders == [
			SessionHolder(vm: "alpha", activity: "is not responding", promptsItself: false),
		])
	}

	@Test @MainActor func aHostThatNeverAnsweredLeavesItToTheAgent() async throws {
		let routing = try makeRouting()
		routing.hostProbeDeadline = .seconds(1)   // the stalled ask runs it out
		let (stub, server) = try await adopt(routing, state: .stopped, stalled: true)
		defer {
			stub.stalled = []
			server.stop()
		}
		#expect(routing.sessionHolders.map(\.promptsItself) == [false])
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

	// E45: a busy older agent refuses retire; the new one's Replace used to time out silently.
	@Test func aRefusedReplaceSaysWhy() throws {
		let prompt = AgentPrompt.replaceRefused(
			reason: "mac is installing macOS \u{2014} try again when it finishes")
		#expect(prompt.message == "The older Machman Agent can\u{2019}t be replaced yet")
		#expect(prompt.info == "mac is installing macOS \u{2014} try again when it finishes.")
		#expect(prompt.buttons == ["OK"])
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		#expect(prompt.info.matches(of: sentenceEnd).count == 1)
	}
}
