//
//  LabAgent.swift
//  MachmanLabTests
//
//  Launches THIS worktree's embedded Debug agent the way the desktop does (NSWorkspace, a new
//  instance with an explicit environment, so it is its own responsible process), under the
//  lab's .test-<token> suite, and drives it over its socket with RemoteMachman. Needs r3-tb's
//  test-mode seams: without them the agent would show a menu-bar item and alerts, so
//  launch() refuses (MACHMAN_LAB_SEAMS) and kills an agent that never logs its banner.
//

import AppKit
import Foundation
import MachmanAPI
import MachmanClient
import MachmanTestSupport

/// A one-holder async mutex: one agent scope at a time, so the two-guest cap cannot race.
actor LabGate {
	static let agents = LabGate()

	private var held = false
	private var waiting: [CheckedContinuation<Void, Never>] = []

	func enter() async {
		if !held {
			held = true
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	func leave() {
		if waiting.isEmpty {
			held = false
		} else {
			waiting.removeFirst().resume()
		}
	}
}

final class LabAgent: @unchecked Sendable {
	struct Options {
		var environment: [String: String] = [:]
		var answers: [String: Any] = [:]
		var appURL: URL?
		var waitForBanner = true
	}

	static let bundleID = "com.gustaffranzen.Machman.dev.agent"

	static var embeddedAppURL: URL {
		URL(fileURLWithPath: Lab.productsDir).appendingPathComponent(
			"MachmanDesktop.app/Contents/Library/LoginItems/MachmanAgent.app")
	}

	private(set) var pid: pid_t
	private(set) var api: RemoteMachman
	let scope: LabScope
	let options: Options
	let appURL: URL
	private var finished = false

	var socketPath: String { MachmanPaths.daemonSocketPath() }

	var bundleVersion: String {
		(Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
	}

	private init(pid: pid_t, api: RemoteMachman, scope: LabScope, options: Options, appURL: URL) {
		self.pid = pid
		self.api = api
		self.scope = scope
		self.options = options
		self.appURL = appURL
	}

	/// The environment of the launched agent (pure): the suite, the scope's library and home,
	/// the lab variables, and blanks for what must not reach it. OpenConfiguration.environment
	/// MERGES onto what the agent would inherit (launchd's SSH_AUTH_SOCK, the test helper's
	/// DYLD_* paths) rather than replacing it, so those are overridden with empty values: an
	/// empty SSH_AUTH_SOCK reads as no ssh-agent, so nothing a lab process runs reaches the
	/// user's keys.
	static let blanked = [
		"SSH_AUTH_SOCK", "SSH_ASKPASS", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
		"DYLD_INSERT_LIBRARIES",
	]

	static func environment(
		scope: LabScope, inherited: [String: String], extra: [String: String]
	) -> [String: String] {
		var result: [String: String] = [:]
		for (key, value) in inherited where key.hasPrefix("MACHMAN_LAB_") { result[key] = value }
		result["MACHMAN_SUITE_ID"] = inherited["MACHMAN_SUITE_ID"]
		result["MACHMAN_DATA_DIR"] = scope.dataDir
		result["CFFIXED_USER_HOME"] = scope.homeDir
		result["HOME"] = scope.homeDir
		result["TMPDIR"] = inherited["TMPDIR"] ?? NSTemporaryDirectory()
		result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
		result["USER"] = inherited["USER"]
		result["LOGNAME"] = inherited["LOGNAME"]
		result["MACHMAN_LAB_ANSWERS"] = scope.answersPath
		result["MACHMAN_LAB_AGENT_CONTROL"] = scope.controlPath
		for key in blanked { result[key] = "" }
		for (key, value) in extra { result[key] = value }
		return result
	}

	static func openInstance(scope: LabScope, options: Options) async throws -> pid_t {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.createsNewApplicationInstance = true
		configuration.activates = false
		configuration.addsToRecentItems = false
		configuration.promptsUserIfNeeded = false
		configuration.arguments = []
		configuration.environment = environment(
			scope: scope, inherited: Lab.environment, extra: options.environment)
		let app = try await NSWorkspace.shared.openApplication(
			at: options.appURL ?? embeddedAppURL, configuration: configuration)
		return app.processIdentifier
	}

	static func launch(scope: LabScope, options: Options = .init()) async throws -> LabAgent {
		guard Lab.seamsPresent else { throw LabError.seamsMissing }
		let url = options.appURL ?? embeddedAppURL
		guard Bundle(url: url)?.bundleIdentifier == bundleID else {
			throw LabError.agentDidNotStart("no Debug agent at \(url.path)")
		}
		if !options.answers.isEmpty { try scope.writeAnswers(options.answers) }
		let mark = LabLog.mark()
		let (pid, api) = try await start(scope: scope, options: options, mark: mark)
		return LabAgent(pid: pid, api: api, scope: scope, options: options, appURL: url)
	}

	// openInstance, connect, banner and peer-pid checks; kills the agent on any failure.
	private static func start(
		scope: LabScope, options: Options, mark: UInt64
	) async throws -> (pid_t, RemoteMachman) {
		let pid = try await openInstance(scope: scope, options: options)
		try LabProcesses.writePid(pid, kind: "agent", name: scope.id)
		func abort(_ error: Error) -> Error {
			LabProcesses.signal(pid, SIGKILL)
			LabProcesses.removePid(kind: "agent", name: scope.id)
			return error
		}
		let deadline = ContinuousClock.now + .seconds(30)
		var connected: RemoteMachman?
		while connected == nil {
			if !LabProcesses.isAlive(pid) { throw abort(LabError.agentDidNotStart("it exited")) }
			do {
				connected = try await RemoteMachman(
					socketPath: MachmanPaths.daemonSocketPath(), clientName: "machman-lab")
			} catch {
				if ContinuousClock.now >= deadline {
					throw abort(LabError.agentDidNotStart("no answer in 30 s (\(error))"))
				}
				try await Task.sleep(for: .milliseconds(250))
			}
		}
		guard let api = connected else { throw abort(LabError.agentDidNotStart("not connected")) }
		if options.waitForBanner {
			let suite = NSRegularExpression.escapedPattern(for: Lab.suiteID)
			do {
				_ = try await LabLog.waitFor(
					"test mode: agent under " + suite, after: mark, timeout: .seconds(20))
			} catch {
				await api.disconnect()
				throw abort(LabError.noTestModeBanner(suite: Lab.suiteID))
			}
		}
		guard api.peerPID == pid else {
			await api.disconnect()
			throw abort(LabError.agentDidNotStart("another agent serves the suite"))
		}
		return (pid, api)
	}

	/// Starts the same agent again in the same scope (the re-adoption rows).
	func relaunch() async throws {
		_ = await LabProcesses.waitForExit(pid, timeout: .seconds(10))
		let mark = LabLog.mark()
		let (newPid, newApi) = try await Self.start(scope: scope, options: options, mark: mark)
		pid = newPid
		api = newApi
		finished = false
	}

	func kill(_ sig: Int32) { LabProcesses.signal(pid, sig) }

	func waitForExit(timeout: Duration) async -> Bool {
		await LabProcesses.waitForExit(pid, timeout: timeout)
	}

	func connect(clientName: String) async throws -> RemoteMachman {
		try await RemoteMachman(socketPath: socketPath, clientName: clientName)
	}

	func setAnswers(_ answers: [String: Any]) throws { try scope.writeAnswers(answers) }

	/// One line to the agent's control socket (ping / quit / menu), one line back.
	func control(_ line: String, timeout: Duration = .seconds(30)) async throws -> String {
		let path = scope.controlPath
		let deadline = ContinuousClock.now + .seconds(10)
		var fd: Int32 = -1
		while fd < 0 {
			fd = await offPool { LabConsole.connectOnce(path) }
			if fd >= 0 { break }
			if ContinuousClock.now >= deadline {
				throw LabError.controlFailed("nothing serves the control socket \(path)")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
		let bytes = Array((line + "\n").utf8)
		_ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
		let seconds = Double(timeout.components.seconds)
		let lines = await SocketLines.read(fd, count: 1, timeout: seconds)
		Darwin.close(fd)
		guard let answer = lines.first else {
			throw LabError.controlFailed("no answer to '\(line)' from the control socket")
		}
		return answer
	}

	/// Force-stops the scope's VMs, retires the agent and reaps everything; idempotent.
	func shutdown() async {
		guard !finished else { return }
		finished = true
		if LabProcesses.isAlive(pid) {
			let running = ((try? await api.listVMs()) ?? []).filter { $0.state.isRunning }
			for vm in running {
				try? await api.stop(vm: vm.name, mode: .force)
			}
			let deadline = ContinuousClock.now + .seconds(30)
			while ContinuousClock.now < deadline {
				let still = ((try? await api.listVMs()) ?? []).contains { $0.state.isRunning }
				if !still { break }
				try? await Task.sleep(for: .milliseconds(250))
			}
			try? await api.retire()
			if await !LabProcesses.waitForExit(pid, timeout: .seconds(15)) {
				LabProcesses.signal(pid, SIGKILL)
				_ = await LabProcesses.waitForExit(pid, timeout: .seconds(5))
			}
		}
		await api.disconnect()
		LabProcesses.removePid(kind: "agent", name: scope.id)
		for host in LabProcesses.pids(kind: "vmhost", namePrefix: scope.id + "-") {
			LabProcesses.signal(host, SIGKILL)
		}
		let names = (try? FileManager.default.contentsOfDirectory(atPath: Lab.pidsDir)) ?? []
		for name in names where name.hasPrefix("vmhost-\(scope.id)-") {
			try? FileManager.default.removeItem(atPath: Lab.pidsDir + "/" + name)
		}
	}
}

extension Lab {
	/// One agent scope for `body`; the agent is shut down on every path, and the gate that
	/// serializes scopes is left exactly once.
	static func withAgent<T>(
		_ options: LabAgent.Options = .init(), _ body: (LabAgent) async throws -> T
	) async throws -> T {
		await LabGate.agents.enter()
		do {
			let scope = try LabScope.make()
			let agent = try await LabAgent.launch(scope: scope, options: options)
			do {
				let result = try await body(agent)
				await agent.shutdown()
				await LabGate.agents.leave()
				return result
			} catch {
				await agent.shutdown()
				throw error
			}
		} catch {
			await LabGate.agents.leave()
			throw error
		}
	}
}
