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
			== .ask([]))
	}

	// Review F10: with a VM running AND a copy in the agent, "Quit, Leave VMs Running" stopped
	// the copy without a word. The VMs' question now carries the work, to ask about it too.
	@Test func theUsersQuitWithVMsRunningCarriesTheAgentsWork() {
		let copying = SessionHolder(
			vm: "beta", activity: "is being copied", promptsItself: false, isAgentWork: true)
		#expect(AgentQuitDecision.decide(
			reason: .userQuit, runningVMs: 1, holders: [running, copying])
			== .ask([copying]))
	}

	// E47: with no VM running, the user's own quit stopped a copy or an install without a
	// word. It asks now; a session end cancels and says what runs (C13).
	@Test func workTheAgentRunsHoldsAQuit() {
		let copying = SessionHolder(
			vm: "gamma", activity: "is being copied", promptsItself: false, isAgentWork: true)
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
			== "Logout was canceled: wait for it or stop it in Machman, then log out again.")
		#expect(one.buttons == ["OK"])
		let both = AgentPrompt.sessionEndHeld(reason: .restart, holders: [starting, starting])
		#expect(both.message == "2 VMs are busy")
		#expect(both.info
			== "Restart was canceled: wait for them or stop them in Machman, then restart again.")
		let off = AgentPrompt.sessionEndHeld(reason: .shutDown, holders: [starting])
		#expect(off.info == "Shutdown was canceled: wait for it or stop it in Machman, then "
			+ "shut down your Mac again.")
		for prompt in [one, both, off] {
			#expect(prompt.info.matches(of: sentenceEnd).count == 1)
			#expect(!prompt.info.lowercased().contains("daemon"))
		}
	}

	// The VM's own prompt is what explains a canceled log out now: US spelling (A-all-2), and
	// the canceled thing as a noun (W6), as the agent's alert says it too.
	@Test("W6: a canceled log out or shut down reads Logout and Shutdown was canceled")
	func theVMsPromptSaysCanceled() {
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .logOut).info
			== "Logout was canceled: shut the VM down, then log out again.")
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .restart).info
			== "Restart was canceled: shut the VM down, then restart again.")
		#expect(HostPrompt.quitWhileRunning("alpha", reason: .shutDown).info
			== "Shutdown was canceled: shut the VM down, then shut down your Mac again.")
		#expect(AgentPrompt.sessionEndHeld(
			reason: .shutDown, holders: [SessionHolder(
				vm: "beta", activity: "is still starting", promptsItself: false)]
		).info.hasPrefix("Shutdown was canceled: "))
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
	// VM, however many copies run into it. A copy its vmhost runs holds it as well, and that
	// vmhost says so itself (V15).
	@Test @MainActor func theAgentsOwnWorkHoldsALogOut() throws {
		let routing = try makeRouting()
		routing.claims.insert("alpha", .importingDisk)
		routing.claims.insert("alpha", .promotingDisk)
		routing.claims.insert("beta", .copying)
		routing.claims.insert("gamma", .importingDisk, inDaemon: false)   // its vmhost's
		#expect(routing.runningVMNames.isEmpty)
		#expect(routing.sessionHolders == [
			SessionHolder(
				vm: "alpha", activity: "is importing a disk", promptsItself: false,
				isAgentWork: true),
			SessionHolder(
				vm: "beta", activity: "is being copied", promptsItself: false, isAgentWork: true),
			SessionHolder(vm: "gamma", activity: "is importing a disk", promptsItself: true),
		])
	}

	// V15: an import the agent proxied to a stopped VM's vmhost held no log out, so the agent
	// quit with the session while that vmhost canceled it (E46) and stayed. It holds one now,
	// quietly — the vmhost's own alert says why — and still never holds the user's own quit:
	// the import goes on in its vmhost without the agent.
	@Test("V15: a vmhost's import for the agent holds a log out quietly, never a quit")
	@MainActor func aVMHostsImportHoldsALogOutQuietly() throws {
		let routing = try makeRouting()
		routing.claims.insert("gamma", .importingDisk, inDaemon: false)
		let holders = routing.sessionHolders
		#expect(holders == [
			SessionHolder(vm: "gamma", activity: "is importing a disk", promptsItself: true),
		])
		for reason in [VMHostQuitReason.logOut, .restart, .shutDown] {
			#expect(AgentQuitDecision.decide(reason: reason, runningVMs: 0, holders: holders)
				== .cancelQuietly)
		}
		#expect(AgentQuitDecision.decide(reason: .userQuit, runningVMs: 0, holders: holders)
			== .quit)
		#expect(routing.daemonWorkRefusal() == nil)   // nor a newer agent's Replace
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
				SessionHolder(
					vm: "mac", activity: "is installing macOS", promptsItself: false,
					isAgentWork: true),
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

	// TB8: under a test suite the lab answers each prompt by its id (LabAnswers); a prompt
	// the answers file doesn't list takes its cancel button, else its first.
	@Test("Q18: every agent prompt has its own lab id and cancel button (TB8)")
	func everyAgentPromptHasItsOwnLabIDAndCancelButton() {
		let holder = SessionHolder(vm: "beta", activity: "is still starting", promptsItself: false)
		let prompts: [(AgentPrompt, String, Int?)] = [
			(.replaceOlder(running: "1.0.11", mine: "1.0.12"), "agent.replaceOlder", 1),
			(.replaceRefused(reason: "It is busy"), "agent.replaceRefused", nil),
			(.sessionEndHeld(reason: .logOut, holders: [holder]), "agent.sessionEndHeld", nil),
			(.quitDuringWork([holder]), "agent.quitDuringWork", 0),
			(.cannotStart(reason: "Its socket path is too long"), "agent.cannotStart", nil),
			(.vmsStillRunning, "agent.vmsStillRunning", 3),
		]
		for (prompt, id, cancel) in prompts {
			#expect(prompt.id == id)
			#expect(prompt.cancelIndex == cancel, "\(id)")
			if let cancel {
				#expect(prompt.buttons.indices.contains(cancel), "\(id)")
			}
			#expect(prompt.labPrompt == LabPrompt(
				id: id, message: prompt.message, info: prompt.info, buttons: prompt.buttons,
				cancelIndex: cancel))
		}
		#expect(Set(prompts.map(\.1)).count == prompts.count)
	}

	// The two alerts the agent used to build inline, moved here word for word.
	@Test("Q18: the moved agent prompts keep their words (TB8)")
	func theMovedAgentPromptsKeepTheirWords() {
		let quit = AgentPrompt.vmsStillRunning
		#expect(quit.message == "VMs are still running")
		#expect(quit.info == "Running VMs live in their own processes: you can quit and leave "
			+ "them running (the next Machman Agent re-adopts them), ask the guests to shut down "
			+ "(force-stopped after 30 seconds), or force stop everything now.")
		#expect(quit.buttons == [
			"Quit, Leave VMs Running", "Shut Down All & Quit", "Force Stop All & Quit", "Cancel",
		])
		let failed = AgentPrompt.cannotStart(reason: "Another copy is already serving its socket")
		#expect(failed.message == "Machman Agent can\u{2019}t start")
		#expect(failed.info == "Another copy is already serving its socket")
		#expect(failed.buttons == ["OK"])
	}
}
