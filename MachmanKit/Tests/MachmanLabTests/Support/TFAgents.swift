//
//  TFAgents.swift
//  MachmanLabTests
//
//  Agent lifecycles the engine rows need beyond LabAgent: a quit through the control socket
//  with its reason, a restart around a hand edit of the library, and a SECOND agent in the
//  same scope (another build, or the same one) with its own pid file (agent-<scope>-b), so
//  the sweeps reap it whatever the test does. Second agents go through LabAgent.openInstance
//  as they are; no harness file changes (T29).
//

import Foundation
import MachmanAPI
import MachmanClient

enum TFAgents {
	/// `quit <reason>` on the control socket; true when the agent then exits within
	/// `timeout`. The reply can race the exit, so a dropped control connection is fine when
	/// the pid goes. False: it stayed (a Cancel, a canceled log out).
	@discardableResult
	static func quit(
		_ agent: LabAgent, reason: String, timeout: Duration = .seconds(10)
	) async throws -> Bool {
		do {
			let answer = try await agent.control("quit \(reason)", timeout: .seconds(10))
			guard answer == "ok" else {
				throw LabError.controlFailed("quit \(reason) answered '\(answer)'")
			}
		} catch let error as LabError {
			guard await agent.waitForExit(timeout: timeout) else { throw error }
			return true
		}
		return await agent.waitForExit(timeout: timeout)
	}

	/// Quits the agent (no VM may run), runs `edit` while nothing serves the library, then
	/// starts the same agent again in the same scope.
	static func restartForEdit(_ agent: LabAgent, _ edit: () throws -> Void) async throws {
		let running = try await agent.api.listVMs().filter { $0.state.isRunning }.map(\.name)
		guard running.isEmpty else {
			throw TFError.precondition("restartForEdit with VMs running: \(running)")
		}
		guard try await quit(agent, reason: "userQuit") else {
			throw TFError.precondition("the agent stayed after quit userQuit with no VM running")
		}
		await agent.api.disconnect()
		try edit()
		try await agent.relaunch()
	}

	static func secondPidName(_ scope: LabScope) -> String { scope.id + "-b" }

	/// A second agent in `scope` (pid file agent-<scope>-b). `options.appURL` picks the build;
	/// its answers come from the scope's file, as the first agent's do.
	static func launchSecond(
		scope: LabScope, options: LabAgent.Options = .init()
	) async throws -> pid_t {
		let pid = try await LabAgent.openInstance(scope: scope, options: options)
		try LabProcesses.writePid(pid, kind: "agent", name: secondPidName(scope))
		return pid
	}

	/// Once `oldPid` exited, a connection whose peer is `newPid` (the takeover's winner).
	static func connectAfterTakeover(
		newPid: pid_t, oldPid: pid_t, socketPath: String, timeout: Duration = .seconds(30)
	) async throws -> RemoteMachman {
		guard await LabProcesses.waitForExit(oldPid, timeout: timeout) else {
			throw TFError.timeout("the old agent \(oldPid) to exit")
		}
		let deadline = ContinuousClock.now + timeout
		while true {
			if let api = try? await RemoteMachman(
				socketPath: socketPath, clientName: "machman-lab-b") {
				if api.peerPID == newPid { return api }
				await api.disconnect()
			}
			if !LabProcesses.isAlive(newPid) {
				throw TFError.precondition("the new agent \(newPid) exited")
			}
			if ContinuousClock.now >= deadline {
				throw TFError.timeout("the new agent \(newPid) to serve its socket")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	/// Force-stops a second agent's running VMs, retires it, kills it if it stays, and
	/// forgets its pid file. Idempotent.
	static func stopSecond(pid: pid_t, api: RemoteMachman?, scope: LabScope) async {
		if LabProcesses.isAlive(pid), let api {
			let running = ((try? await api.listVMs()) ?? []).filter { $0.state.isRunning }
			for vm in running { try? await api.stop(vm: vm.name, mode: .force) }
			let deadline = ContinuousClock.now + .seconds(30)
			while ContinuousClock.now < deadline,
				((try? await api.listVMs()) ?? []).contains(where: { $0.state.isRunning }) {
				try? await Task.sleep(for: .milliseconds(250))
			}
			try? await api.retire()
		}
		await api?.disconnect()
		if await !LabProcesses.waitForExit(pid, timeout: .seconds(15)) {
			if TFProcess.isAgent(pid) { kill(pid, SIGKILL) }
			_ = await LabProcesses.waitForExit(pid, timeout: .seconds(5))
		}
		LabProcesses.removePid(kind: "agent", name: secondPidName(scope))
	}

	/// The lab log's lines from `pid` after `mark` whose message matches `pattern`.
	static func logLines(after mark: UInt64, pid: pid_t, matching pattern: String) -> [String] {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
		return LabLog.entries(after: mark).filter { $0.processID == Int(pid) }.map(\.eventMessage)
			.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
	}
}
