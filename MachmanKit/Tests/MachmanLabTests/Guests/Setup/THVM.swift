//
//  THVM.swift
//  MachmanLabTests
//
//  A handle on a lab agent's VM by name that follows a rename and stands for a copy (LabVM's
//  name is fixed at creation). Its vmhost's pid file uses LabVM's naming, so the lab's guest
//  cap and sweeps see it; the host paths are the VM folder's (share, payload, report).
//

import Darwin
import Foundation
import MachmanAPI
import MachmanClient

final class THVM: @unchecked Sendable {
	let agent: LabAgent
	private(set) var name: String

	init(agent: LabAgent, name: String) {
		self.agent = agent
		self.name = name
	}

	var api: RemoteMachman { agent.api }

	private var pidName: String { "\(agent.scope.id)-\(name)" }

	/// The VM's folder in the scope's library.
	var vmDir: String { MachmanPaths.vmsDir(dataDir: agent.scope.dataDir) + "/" + name }
	var shareDir: String { vmDir + "/share" }
	var payloadDir: String { shareDir + "/" + GuestSetupInstallerInfo.directoryName }
	var reportDir: String { shareDir + "/" + GuestSetupInstallerInfo.reportDirectoryName }
	var reportFile: String { reportDir + "/" + GuestSetupInstallerInfo.reportName }

	/// A new VM from `spec` (LabVM's builder: the .blank template, clones of its images).
	static func create(_ spec: LabVMSpec, on agent: LabAgent) async throws -> THVM {
		let vm = try await LabVM.create(spec, on: agent)
		return THVM(agent: agent, name: vm.name)
	}

	func info() async throws -> VMInfo { try await api.vm(named: name) }

	func start(timeout: Duration = .seconds(120)) async throws {
		let running = LabProcesses.liveGuestCount()
		if running >= 2 { throw LabError.guestCap(running: running) }
		try await api.start(vm: name, options: StartOptions(openWindow: false))
		try await waitForState(.running, timeout: timeout)
		try LabProcesses.writePid(try await hostPID(), kind: "vmhost", name: pidName)
	}

	func stop(_ mode: StopMode = .force, timeout: Duration = .seconds(120)) async throws {
		try await api.stop(vm: name, mode: mode)
		try await guestStopped(timeout: timeout)
	}

	/// Waits for state stopped and for the vmhost to exit (until then the agent still counts
	/// the VM as hosted and refuses edits), then drops the pid file.
	func guestStopped(timeout: Duration = .seconds(180)) async throws {
		try await waitForState(.stopped, timeout: timeout)
		await awaitHostExit()
	}

	/// Stop (the guest shuts down when `soft`) and start again: VZ has no reset, so this is
	/// what a guest reboot is too.
	func restart(_ mode: StopMode = .force) async throws {
		try await stop(mode)
		try await start()
	}

	/// SIGKILL of the vmhost (a crash, as the force-quit rows have it); waits for stopped.
	func forceQuit() async throws {
		let pid = try await hostPID()
		LabProcesses.signal(pid, SIGKILL)
		_ = await LabProcesses.waitForExit(pid, timeout: .seconds(30))
		try await waitForState(.stopped, timeout: .seconds(60))
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	/// Renames a stopped VM; the handle follows.
	func rename(to newName: String) async throws {
		try await settled { try await self.api.renameVM(named: self.name, to: newName) }
		name = newName
	}

	/// A duplicate of this stopped VM with a fresh MAC (the copy flow's default).
	func copy(as newName: String) async throws -> THVM {
		let made = try await api.copyVM(
			vm: name, newName: newName, diskIDs: nil, regenerateMAC: true)
		return THVM(agent: agent, name: made.name)
	}

	func waitForState(_ wanted: VMState, timeout: Duration) async throws {
		try await LabStep.run(
			"\(name): waiting ≤\(LabStep.format(timeout)) for \(wanted.rawValue)"
		) {
			let deadline = ContinuousClock.now + timeout
			var last = "unknown"
			while true {
				let state = try await info().state
				last = state.rawValue
				if state == wanted { return }
				if state == .error {
					throw LabError.stateTimeout(vm: name, wanted: wanted.rawValue, last: "error")
				}
				if ContinuousClock.now >= deadline {
					throw LabError.stateTimeout(vm: name, wanted: wanted.rawValue, last: last)
				}
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}

	/// The vmhost's pid, through its socket's peer.
	func hostPID() async throws -> pid_t {
		let host = try await RemoteMachman(
			socketPath: MachmanPaths.vmSocketPath(vm: name), clientName: "machman-lab-th")
		let pid = host.peerPID
		await host.disconnect()
		guard let pid else { throw LabError.agentDidNotStart("no peer pid for \(name)'s vmhost") }
		return pid
	}

	func consoleSocketPath(_ index: Int) async throws -> String {
		let deadline = ContinuousClock.now + .seconds(15)
		while true {
			let ports = try await info().consolePorts ?? []
			if let path = ports.first(where: { $0.index == index })?.socketPath { return path }
			if ContinuousClock.now >= deadline {
				throw LabError.consoleUnavailable("\(name) has no console \(index) socket")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	/// Console port `index`, its transcript named after the VM and `label`.
	func console(_ index: Int, label: String) async throws -> LabConsole {
		try await LabConsole.connect(
			try await consoleSocketPath(index), transcript: transcriptName(label),
			title: "\(name) \(label)")
	}

	private func transcriptName(_ label: String) -> String {
		let safe = String(pidName.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
		return "th-\(safe)-\(label)-\(THCounter.next())"
	}

	/// `user` logged in on console `index`: a console that takes no input (the getty's
	/// prompt arrives, typed text never reaches it — seen under VZ about one boot in ten) is
	/// retried on a fresh connection, `tries` in all.
	func loggedInConsole(
		_ index: Int, user: String = "root", password: String? = nil, label: String,
		timeout: Duration = .seconds(300), tries: Int = 2
	) async throws -> LabConsole {
		var attempt = 1
		while true {
			let console = try await console(index, label: label)
			do {
				try await console.login(
					user: user, password: password,
					timeout: attempt == 1 ? timeout : .seconds(60))
				return console
			} catch let error as LabError where attempt < tries {
				MachmanLogger.log(
					.passiveWarning,
					"lab: \(name) console \(index): login try \(attempt) failed: \(error)")
				console.close()
				attempt += 1
				try await Task.sleep(for: .seconds(1))
			}
		}
	}

	/// Starts the VM unless it runs and logs `user` in on console `index`; a boot whose
	/// console takes no input is force-stopped and booted again, `boots` boots in all.
	func bootLoggedIn(
		_ index: Int, user: String = "root", label: String, boots: Int = 3
	) async throws -> LabConsole {
		var boot = 1
		while true {
			if try await info().state != .running { try await start() }
			do {
				return try await loggedInConsole(index, user: user, label: label)
			} catch let error as LabError where boot < boots {
				MachmanLogger.log(
					.passiveWarning,
					"lab: \(name) console \(index): no login on boot \(boot) of \(boots), "
						+ "booting again: \(error)")
				try await stop(.force)
				boot += 1
			}
		}
	}

	/// Stopped (forced) if it runs, then deleted; for every exit path.
	func cleanup() async {
		if let state = try? await info().state, state.isRunning {
			try? await api.stop(vm: name, mode: .force)
			try? await guestStopped(timeout: .seconds(60))
		}
		try? await api.deleteVM(named: name)
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	private func awaitHostExit() async {
		let file = LabProcesses.pidFile(kind: "vmhost", name: pidName)
		if let text = try? String(contentsOfFile: file, encoding: .utf8),
			let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
			_ = await LabProcesses.waitForExit(pid, timeout: .seconds(30))
		}
		LabProcesses.removePid(kind: "vmhost", name: pidName)
	}

	// `body`, retried for a while as the agent settles a stop (invalidState).
	private func settled<T>(_ body: () async throws -> T) async throws -> T {
		let deadline = ContinuousClock.now + .seconds(30)
		while true {
			do {
				return try await body()
			} catch let error as MachmanError
				where error.code == .invalidState && ContinuousClock.now < deadline {
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}
}

/// Run-wide unique numbers (transcript names, console markers).
enum THCounter {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var value = 0

	static func next() -> Int {
		lock.withLock {
			value += 1
			return value
		}
	}
}
