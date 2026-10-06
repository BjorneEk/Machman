//
//  TFHosts.swift
//  MachmanLabTests
//
//  A test-suite vmhost's own control socket, beside its agent's (LabControlPath.vmhost):
//  `ping`, and `quit <reason>` — a log out, restart or shut down reaches the vmhost without an
//  Apple Event (Q23). The reply comes before the quit acts, so it is never lost to the exit.
//

import Darwin
import Foundation
import MachmanAPI
import MachmanTestSupport

enum TFHosts {
	static func controlPath(_ agent: LabAgent, vm: String) -> String {
		LabControlPath.vmhost(agentControl: agent.scope.controlPath, vm: vm)
	}

	/// One line to `vm`'s vmhost control socket, one line back.
	static func control(
		_ agent: LabAgent, vm: String, _ line: String, timeout: Duration = .seconds(30)
	) async throws -> String {
		let path = controlPath(agent, vm: vm)
		let deadline = ContinuousClock.now + .seconds(10)
		var fd: Int32 = -1
		while fd < 0 {
			fd = await offPool { LabConsole.connectOnce(path) }
			if fd >= 0 { break }
			if ContinuousClock.now >= deadline {
				throw LabError.controlFailed("nothing serves the vmhost control socket \(path)")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
		let bytes = Array((line + "\n").utf8)
		_ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
		let lines = await SocketLines.read(
			fd, count: 1, timeout: Double(timeout.components.seconds))
		Darwin.close(fd)
		guard let answer = lines.first else {
			throw LabError.controlFailed("no answer to '\(line)' from \(vm)'s vmhost")
		}
		return answer
	}

	/// `quit <reason>` to `vm`'s vmhost (pid `host`); true when it then exits within
	/// `timeout`, false when it stayed (a canceled log out, a Cancel).
	static func quit(
		_ agent: LabAgent, vm: String, host: pid_t, reason: String,
		timeout: Duration = .seconds(10)
	) async throws -> Bool {
		let answer = try await control(agent, vm: vm, "quit \(reason)")
		guard answer == "ok" else {
			throw LabError.controlFailed("quit \(reason) answered '\(answer)' from \(vm)'s vmhost")
		}
		return await LabProcesses.waitForExit(host, timeout: timeout)
	}
}
