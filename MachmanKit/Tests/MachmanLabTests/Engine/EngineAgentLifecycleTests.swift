//
//  EngineAgentLifecycleTests.swift
//  MachmanLabTests
//
//  L2 — the agent's own life: its sockets' keep-alive (E10), a start cut off by the agent's
//  death (E12), and its quit decisions for a log out, a restart and the user's quit with VMs
//  running (V7). Quits come through the lab control socket with their reason; nothing logs
//  out the real session. The VM's own log-out alert is its vmhost's, quit the same way on the
//  vmhost's own control socket (Q23).
//

import AppKit
import Darwin
import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite("Engine — agent lifecycle", .serialized, .enabled(if: Lab.runs(.l2)))
struct EngineAgentLifecycleTests {
	static func mtime(_ path: String) -> Double? {
		var info = stat()
		guard stat(path, &info) == 0 else { return nil }
		return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
	}

	/// Waits until `path`'s mtime passes `after`; returns the new mtime.
	static func touched(_ path: String, after: Double, within: Duration) async throws -> Double {
		var seen: Double?
		try await TFWait.until(
			"\(path) to be touched", timeout: within, every: .milliseconds(100)
		) {
			seen = mtime(path)
			return (seen ?? 0) > after
		}
		return seen!
	}

	@Test("W1-19: the agent refreshes its socket's timestamps on the lab interval")
	func socketsKeptAlive() async throws {
		let options = LabAgent.Options(environment: ["MACHMAN_LAB_KEEPALIVE_SECONDS": "2"])
		try await Lab.withAgent(options) { agent in
			let socket = agent.socketPath
			let dir = (socket as NSString).deletingLastPathComponent
			let t0 = try #require(Self.mtime(socket))
			let d0 = try #require(Self.mtime(dir))
			// The interval is 2 s: a touch within 8 s that lands at least a second later,
			// then another 3 s on.
			let first = try await Self.touched(socket, after: t0 + 1, within: .seconds(8))
			_ = try await Self.touched(socket, after: first + 1, within: .seconds(6))
			#expect((Self.mtime(dir) ?? 0) > d0)
			let mark = LabLog.mark()
			try await agent.withVM(LabVMSpec(name: "keepalive", boot: .alpine())) { vm in
				let inherits = try await LabLog.waitFor(
					"test mode: vmhost for keepalive inherits ", after: mark,
					process: "MachmanAgent")
				#expect(inherits.eventMessage.contains("MACHMAN_LAB_KEEPALIVE_SECONDS"))
				let vmSocket = MachmanPaths.vmSocketPath(vm: vm.name)
				let v0 = try #require(Self.mtime(vmSocket))
				let next = try await Self.touched(vmSocket, after: v0 + 1, within: .seconds(8))
				_ = try await Self.touched(vmSocket, after: next + 1, within: .seconds(6))
			}
		}
	}

	// Q23: the console sockets kept the hour-long default under a lab run, so W1-19 covered
	// only the agent's and the vmhost's control sockets.
	@Test("Q23: a VM's console sockets refresh their timestamps on the lab interval")
	func consoleSocketsKeptAlive() async throws {
		let options = LabAgent.Options(environment: ["MACHMAN_LAB_KEEPALIVE_SECONDS": "2"])
		try await Lab.withAgent(options) { agent in
			try await agent.withVM(LabVMSpec(name: "console-keepalive", boot: .alpine())) { vm in
				for index in 0..<2 {
					let socket = try await vm.consoleSocketPath(index)
					let t0 = try #require(Self.mtime(socket))
					let first = try await Self.touched(socket, after: t0 + 1, within: .seconds(8))
					_ = try await Self.touched(socket, after: first + 1, within: .seconds(6))
				}
			}
		}
	}

	@Test(
		"""
		W1-22: after the agent dies within a start's first second, the next agent starts \
		the VM at once
		""")
	func startAfterKilledAgent() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(
				LabVMSpec(name: "start-after-crash", boot: .alpine()), start: false
			) { vm in
				let socket = MachmanPaths.vmSocketPath(vm: vm.name)
				var proven = false
				for attempt in 1...3 {
					let api = agent.api
					let start = Task {
						try? await api.start(
							vm: "start-after-crash", options: StartOptions(openWindow: false))
					}
					let sent = ContinuousClock.now
					while !FileManager.default.fileExists(atPath: socket),
						ContinuousClock.now - sent < .seconds(3) {
						try await Task.sleep(for: .milliseconds(50))
					}
					agent.kill(SIGKILL)
					_ = await start.value
					let mark = LabLog.mark()
					try await agent.relaunch()
					// The kill came after the start went through: nothing to prove this time.
					if try await vm.info().state == .running {
						MachmanLogger.log(.passiveWarning,
							"lab: attempt \(attempt): the VM was running before the kill")
						_ = try? await TFVM.recordHost(agent, "start-after-crash")
						await TFVM.forceStop(agent, "start-after-crash")
						continue
					}
					let began = ContinuousClock.now
					try await agent.api.start(
						vm: "start-after-crash", options: StartOptions(openWindow: false))
					try await vm.waitForState(.running, timeout: .seconds(20))
					#expect(ContinuousClock.now - began < .seconds(20))
					_ = try await TFVM.recordHost(agent, "start-after-crash")
					#expect(LabLog.count("already running", after: mark) == 0)
					proven = true
					break
				}
				if !proven {
					throw TFError.inconclusive("three starts finished before the kill landed")
				}
			}
		}
	}

	@Test(
		"""
		W4-17: a log out with a VM running is canceled quietly, and proceeds once the VM is \
		down
		""")
	func logOutWithVMRunning() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "running-at-logout", boot: .alpine())) { vm in
				let mark = LabLog.mark()
				let exited = try await TFAgents.quit(agent, reason: "logOut", timeout: .seconds(3))
				#expect(!exited)
				let canceled = try await LabLog.waitFor(
					"logOut canceled: running-at-logout still running", after: mark,
					process: "MachmanAgent")
				#expect(canceled.processID == Int(agent.pid))
				#expect(LabLog.count("test prompt agent\\.", after: mark) == 0)
				#expect(try await agent.control("ping") == "ok")
				try await vm.stop()
				let again = LabLog.mark()
				#expect(try await TFAgents.quit(agent, reason: "logOut"))
				#expect(LabLog.count("test prompt ", after: again) == 0)
			}
		}
	}

	@Test(
		"""
		W4-17: a vmhost asked to log out, restart or shut down under its running VM cancels \
		and asks
		""")
	func vmhostCancelsASessionEnd() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "vm-at-logout", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				#expect(NSRunningApplication(processIdentifier: host)?.activationPolicy
					== .prohibited)
				// Unlisted, the answer is Keep Running: the VM and its vmhost stay.
				for reason in ["logOut", "restart", "shutDown"] {
					let mark = LabLog.mark()
					#expect(try await !TFHosts.quit(
						agent, vm: vm.name, host: host, reason: reason, timeout: .seconds(3)))
					let asked = try await LabLog.waitFor(
						SeamProbe.promptLine("vmhost.sessionEndWhileRunning", "Keep Running"),
						after: mark, process: "MachmanVMHost")
					#expect(asked.processID == Int(host))
					#expect(try await vm.info().state == .running)
				}
				// The user's own quit asks the other question; unlisted, it takes Cancel.
				var mark = LabLog.mark()
				#expect(try await !TFHosts.quit(
					agent, vm: vm.name, host: host, reason: "userQuit", timeout: .seconds(3)))
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("vmhost.quitWhileRunning", "Cancel"), after: mark,
					process: "MachmanVMHost")
				// Force Stop VM: the VM stops, and its vmhost exits after it.
				try agent.setAnswers(["vmhost.sessionEndWhileRunning": "Force Stop VM"])
				mark = LabLog.mark()
				#expect(try await TFHosts.quit(
					agent, vm: vm.name, host: host, reason: "logOut", timeout: .seconds(30)))
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("vmhost.sessionEndWhileRunning", "Force Stop VM"),
					after: mark, process: "MachmanVMHost")
				try await vm.waitForState(.stopped, timeout: .seconds(30))
				TFVM.forget(agent, vm.name)
			}
		}
	}

	@Test("W4-18: a restart with no VM running quits the agent without a prompt")
	func restartWithNothingRunning() async throws {
		try await Lab.withAgent { agent in
			let mark = LabLog.mark()
			let exited = try await TFAgents.quit(agent, reason: "restart")
			#expect(exited)
			#expect(LabLog.count("test prompt ", after: mark) == 0)
		}
	}

	enum QuitChoice: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case leave = "Quit, Leave VMs Running"
		case shutDown = "Shut Down All & Quit"
		case forceStop = "Force Stop All & Quit"
		case cancel = "Cancel"

		var testDescription: String { rawValue }
	}

	@Test(
		"W4-19: each answer to the still-running prompt does what it says",
		arguments: QuitChoice.allCases)
	func stillRunningAnswers(_ choice: QuitChoice) async throws {
		let options = LabAgent.Options(answers: ["agent.vmsStillRunning": choice.rawValue])
		try await Lab.withAgent(options) { agent in
			try await agent.withVM(LabVMSpec(name: "running-at-quit", boot: .alpine())) { vm in
				let host = try await vm.hostPID()
				let mark = LabLog.mark()
				let pattern = NSRegularExpression.escapedPattern(for: choice.rawValue)
				let deadline: Duration = choice == .shutDown ? .seconds(60) : .seconds(30)
				let exited = try await TFAgents.quit(
					agent, reason: "userQuit", timeout: choice == .cancel ? .seconds(3) : deadline)
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.vmsStillRunning", pattern + "$"), after: mark,
					process: "MachmanAgent")
				switch choice {
				case .leave:
					#expect(exited)
					#expect(LabProcesses.isAlive(host))
					try await agent.relaunch()
					let info = try await vm.info()
					#expect(info.state == .running)
					#expect(try await vm.hostPID() == host)
				case .shutDown, .forceStop:
					#expect(exited)
					#expect(await LabProcesses.waitForExit(host, timeout: .seconds(15)))
					TFVM.forget(agent, vm.name)
				case .cancel:
					#expect(!exited)
					#expect(try await agent.control("ping") == "ok")
					#expect(try await vm.info().state == .running)
					#expect(LabProcesses.isAlive(host))
				}
			}
		}
	}
}
