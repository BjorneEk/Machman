//
//  EngineFrozenHostTests.swift
//  MachmanLabTests
//
//  L2 — a frozen vmhost (SIGSTOP) as the agent's menu and quit see it: across an agent
//  restart its VM is unknown, offers stops and no starts (V11, P37), and the agent's Force
//  Stop and Force Stop All & Quit ask before they end its process (E36). Prompts are
//  answered from the scope's answers file and logged; the menu items come through the lab
//  control socket under the menu's own enabled rule.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanUI
@testable import MachmanDesktopCore

@Suite("Engine — frozen vmhosts", .serialized, .enabled(if: Lab.runs(.l2)))
struct EngineFrozenHostTests {
	/// A running VM whose vmhost is frozen, the agent quit leaving it and started again: the
	/// new agent meets a vmhost that never answers. Returns the vmhost's pid (still stopped).
	static func frozenAcrossRestart(_ agent: LabAgent, _ vm: LabVM) async throws -> pid_t {
		let host = try await vm.hostPID()
		try #require(TFProcess.stop(host))
		try agent.setAnswers(["agent.vmsStillRunning": "Quit, Leave VMs Running"])
		guard try await TFAgents.quit(agent, reason: "userQuit", timeout: .seconds(30)) else {
			throw TFError.precondition("the agent stayed after Quit, Leave VMs Running")
		}
		try agent.setAnswers([:])
		try await agent.relaunch()
		try await TFWait.vm(agent.api, vm.name, "unknown", timeout: .seconds(45)) {
			$0.mayBeRunning && ($0.state == .unknown || $0.isUnresponsive)
		}
		return host
	}

	@Test("R3W2-7: after an agent restart a frozen vmhost's VM offers stops but no starts")
	func frozenOffersStopsNoStarts() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "frozen-readopted", boot: .alpine())) { vm in
				let host = try await Self.frozenAcrossRestart(agent, vm)
				defer { TFProcess.resume(host) }
				for action in ["start", "startHeadless", "startSafe"] {
					#expect(
						try await agent.control("menu \(action) frozen-readopted") == "disabled")
				}
				var mark = LabLog.mark()
				#expect(
					try await SeamProbe.control(agent, "menu shutDown frozen-readopted") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.actionFailed", "OK"), after: mark,
					process: "MachmanAgent", timeout: .seconds(30))
				let failed = try await LabLog.waitFor(
					"Couldn’t shut down “frozen-readopted”: ", after: mark, process: "MachmanAgent")
				#expect(failed.eventMessage.contains("not responding"))
				mark = LabLog.mark()
				#expect(
					try await SeamProbe.control(agent, "menu forceStop frozen-readopted") == "ok")
				// What the Force Stop then does: C9 says ask to end the process (E53: the failed
				// adoption has the menu list it Not responding). Recorded, not thrown, so the
				// frozen vmhost is resumed below.
				do {
					_ = try await LabLog.waitFor(
						SeamProbe.promptLine("agent.endProcess", "Cancel \\(not listed\\)"),
						after: mark, process: "MachmanAgent", timeout: .seconds(20))
				} catch {
					Issue.record(Comment(rawValue:
						"Force Stop on the frozen VM never asked to end its process: \(error)"))
				}
				#expect(try await vm.info().name == "frozen-readopted")
				#expect(LabProcesses.isAlive(host))
				TFProcess.resume(host)
				try await TFWait.vm(
					agent.api, "frozen-readopted", "running again", timeout: .seconds(30)
				) {
					$0.state == .running && !$0.isUnresponsive
				}
			}
		}
	}

	@Test("R3W2-44: a frozen VM's stop-first actions wait for Machman Agent to reach it")
	@MainActor
	func frozenStopFirstActionsWait() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "frozen-stop-first", boot: .alpine())) { vm in
				let host = try await Self.frozenAcrossRestart(agent, vm)
				defer { TFProcess.resume(host) }
				let info = try await TFWait.vm(
					agent.api, "frozen-stop-first", "unknown", timeout: .seconds(30)
				) {
					$0.state == .unknown
				}
				for action in [StoppedOnly.regenerateMAC, .installMacOS, .renameVM] {
					#expect(info.refusal(action) == VMInfo.unreachedHelp)
				}
				let desktop = try await TFDesktop.make(agent: agent)
				let listed = try await desktop.waitForEntry(
					"frozen-stop-first", "unknown", timeout: .seconds(10)
				) {
					$0.state == .unknown
				}
				#expect(!desktop.viewModel.canStart(listed))
				#expect(listed.refusal(.deleteVM) == VMInfo.unreachedHelp)
				await desktop.close()
				TFProcess.resume(host)
				try await TFWait.vm(
					agent.api, "frozen-stop-first", "running again", timeout: .seconds(30)
				) {
					$0.state == .running && !$0.isUnresponsive
				}
			}
		}
	}

	@Test("R3W2-28: the agent's Force Stop on a frozen VM asks, then ends its process")
	func agentForceStopEndsFrozen() async throws {
		let options = LabAgent.Options(answers: ["agent.endProcess": "End Process"])
		try await Lab.withAgent(options) { agent in
			try await agent.withVM(LabVMSpec(name: "frozen-menu", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				try #require(TFProcess.stop(host))
				defer { TFProcess.resume(host) }
				try await TFWait.vm(agent.api, vm.name, "not responding", timeout: .seconds(20)) {
					$0.isUnresponsive
				}
				let mark = LabLog.mark()
				#expect(try await SeamProbe.control(agent, "menu forceStop frozen-menu") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.endProcess", "End Process$"), after: mark,
					process: "MachmanAgent", timeout: .seconds(40))
				try await vm.waitForState(.stopped, timeout: .seconds(20))
				#expect(await LabProcesses.waitForExit(host, timeout: .seconds(20)))
				TFVM.forget(agent, vm.name)
			}
		}
	}

	@Test(
		"""
		R3W2-28: Force Stop All & Quit asks about a frozen VM and does what each answer \
		says
		""",
		arguments: ["End Process", "Leave Running"])
	func quitAsksAboutFrozen(_ answer: String) async throws {
		let options = LabAgent.Options(answers: [
			"agent.vmsStillRunning": "Force Stop All & Quit", "agent.endProcessOnQuit": answer,
		])
		try await Lab.withAgent(options) { agent in
			try await agent.withVM(LabVMSpec(name: "frozen-quit", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				try #require(TFProcess.stop(host))
				defer { TFProcess.resume(host) }
				let mark = LabLog.mark()
				let exited = try await TFAgents.quit(
					agent, reason: "userQuit", timeout: .seconds(60))
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine(
						"agent.endProcessOnQuit",
						NSRegularExpression.escapedPattern(for: answer) + "$"),
					after: mark, process: "MachmanAgent", timeout: .seconds(5))
				#expect(exited)
				if answer == "End Process" {
					#expect(await LabProcesses.waitForExit(host, timeout: .seconds(20)))
				} else {
					#expect(LabProcesses.isAlive(host))
					TFProcess.resume(host)
					TFProcess.killLabApp(host)
					#expect(await LabProcesses.waitForExit(host, timeout: .seconds(15)))
				}
				TFVM.forget(agent, vm.name)
			}
		}
	}
}
