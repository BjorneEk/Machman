//
//  TGAutostartTests.swift
//  MachmanLabTests
//
//  launchd tier (T4: lab.sh --launchd only) — the autostart matrix. A VM's Start at login
//  writes its job plist into the scope's fake home and launches nothing; loaded by hand
//  (`launchctl bootstrap`, as at login) the job boots the VM with no agent, the agent adopts
//  it once, a guest power-off isn't respawned, a start before adoption probe-adopts, and
//  turning the switch off removes the plist (booting the job out only when nothing runs).
//  Every job a test loads is booted out on every path; the real log-out/log-in stays
//  Deferred: assisted.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient

@Suite("Autostart under launchd", .serialized, .enabled(if: Lab.runs(.launchd)))
struct TGAutostartTests {
	static let atLogin = StartPolicy(windowed: false, autostart: true)
	static let manual = StartPolicy(windowed: false)

	/// The agent's VM over the vmhost's own socket (no agent involved), until it runs.
	static func waitRunningOnSocket(_ vm: TGVM, timeout: Duration = .seconds(60)) async throws
		-> pid_t {
		guard await TG.waitForSocket(vm.socketPath, timeout: timeout) else {
			throw LabError.stateTimeout(vm: vm.name, wanted: "a live socket", last: "none")
		}
		let host = try await RemoteMachman(socketPath: vm.socketPath, clientName: "machman-lab-tg")
		defer { Task { await host.disconnect() } }
		let deadline = ContinuousClock.now + timeout
		while try await host.vm(named: vm.name).state != .running {
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(vm: vm.name, wanted: "running", last: "not running")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
		guard let pid = host.peerPID else {
			throw LabError.agentDidNotStart("no peer pid on \(vm.name)'s socket")
		}
		return pid
	}

	@Test("Autostart matrix: turning Start at login on writes the plist and launches nothing")
	func plistWrittenNothingLaunched() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-plist", on: agent)
			let path = TGLaunchd.plistPath(agent.scope, vm.name)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let job = try TGLaunchd.readPlist(path)
			#expect(job.label == TGLaunchd.label(vm.name))
			#expect(job.runAtLoad == true)
			#expect(job.keepAlive == false)
			#expect(job.sessionType == "Aqua")
			let executable = try #require(job.arguments.first)
			#expect(executable.hasPrefix(Lab.productsDir + "/"))
			#expect(executable.hasSuffix("/MachmanVMHost"))
			#expect(Array(job.arguments.dropFirst()) == [
				"--data-dir", TG.vmsDir(agent.scope), "--vm", vm.name, "--socket", vm.socketPath,
				"--autostart",
			])
			let env = job.environment
			#expect(env["MACHMAN_SUITE_ID"] == Lab.suiteID)
			#expect(env["CFFIXED_USER_HOME"] == agent.scope.homeDir)
			#expect(env["HOME"] == agent.scope.homeDir)
			#expect(env["MACHMAN_DATA_DIR"] == agent.scope.dataDir)
			#expect(env["MACHMAN_LAB_ANSWERS"] == agent.scope.answersPath)
			#expect(env["MACHMAN_LAB"] == nil)
			#expect(env["PATH"] == nil)
			// Written, never loaded: nothing runs.
			try await Task.sleep(for: .seconds(3))
			#expect(try await TGLaunchd.state(job.label).loaded == false)
			#expect(await !TG.isSocketLive(vm.socketPath))
			#expect(try await TG.vmhostPids(socketPath: vm.socketPath).isEmpty)
		}
	}

	@Test("Autostart matrix: a job boots with no agent, is adopted once and isn't respawned")
	func jobBootsAdoptedNotRespawned() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-boot", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let plist = TGLaunchd.plistPath(agent.scope, vm.name)
			let label = TGLaunchd.label(vm.name)
			try await TGLaunchd.withJobs { jobs in
				// No agent: retired (nothing runs, so nothing asks).
				try await agent.api.retire()
				#expect(await agent.waitForExit(timeout: .seconds(15)))
				try await jobs.bootstrap(plist)
				let host = try await Self.waitRunningOnSocket(vm)
				try vm.fileHostPid(host)
				#expect(try await TGLaunchd.state(label).pid == host)
				#expect(await !TG.isSocketLive(agent.socketPath))
				// The agent adopts it: the same vmhost, and no second one.
				try await agent.relaunch()
				#expect(await TG.until { (try? await vm.info())?.state == .running })
				#expect(try await vm.hostPID() == host)
				#expect(try await TG.vmhostPids(socketPath: vm.socketPath) == [host])
				// The guest powers off: launchd doesn't start it again (KeepAlive false).
				let guest = try await vm.guest()
				try guest.powerOff()
				guest.console.close()
				try await vm.stopped(host: host, timeout: .seconds(30))
				#expect(!LabProcesses.isAlive(host))
				try await Task.sleep(for: .seconds(5))
				#expect(try await TGLaunchd.state(label).pid == nil)
				#expect(try await TG.vmhostPids(socketPath: vm.socketPath).isEmpty)
				#expect(try await vm.info().state == .stopped)
			}
		}
	}

	@Test("Autostart matrix: a start before adoption probe-adopts the job's vmhost")
	func startBeforeAdoptionProbeAdopts() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-adopt", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let plist = TGLaunchd.plistPath(agent.scope, vm.name)
			let label = TGLaunchd.label(vm.name)
			try await TGLaunchd.withJobs { jobs in
				try await jobs.bootstrap(plist)
				// Raw connects only: a list now would adopt the host before the start (F12).
				#expect(await TG.waitForSocket(vm.socketPath, timeout: .seconds(30)))
				try await agent.api.start(vm: vm.name, options: StartOptions(openWindow: false))
				try await vm.waitForState(.running, timeout: .seconds(60))
				let host = try await vm.hostPID()
				try vm.fileHostPid(host)
				#expect(try await TGLaunchd.state(label).pid == host)
				#expect(try await TG.vmhostPids(socketPath: vm.socketPath) == [host])
				try await vm.forceStop()
			}
		}
	}

	@Test("Autostart matrix: off while running keeps the VM; off while stopped boots the job out")
	func switchOffRunningAndStopped() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-off", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let plist = TGLaunchd.plistPath(agent.scope, vm.name)
			let label = TGLaunchd.label(vm.name)
			try await TGLaunchd.withJobs { jobs in
				try await jobs.bootstrap(plist)
				#expect(await TG.until(timeout: .seconds(60)) {
					(try? await vm.info())?.state == .running
				})
				let host = try await vm.hostPID()
				try vm.fileHostPid(host)
				// Off while it runs: the plist goes, the job and its VM stay.
				try await agent.api.setStartPolicy(vm: vm.name, policy: Self.manual)
				#expect(!FileManager.default.fileExists(atPath: plist))
				let running = try await TGLaunchd.state(label)
				#expect(running.loaded)
				#expect(running.pid == host)
				#expect(try await vm.info().state == .running)
				try await vm.forceStop()
				#expect(!LabProcesses.isAlive(host))
				// The agent drops the host a moment after it exits; until then it boots
				// nothing out (a live job's guest would go with it).
				try await Task.sleep(for: .seconds(2))
				// Off while stopped: the plist goes and the job is booted out.
				try await TG.settled {
					try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
				}
				#expect(FileManager.default.fileExists(atPath: plist))
				try await agent.api.setStartPolicy(vm: vm.name, policy: Self.manual)
				#expect(!FileManager.default.fileExists(atPath: plist))
				#expect(await TG.until(timeout: .seconds(10)) {
					(try? await TGLaunchd.state(label).loaded) == false
				})
			}
		}
	}

	@Test("Autostart matrix: rename moves the plist and delete removes it")
	func renameMovesDeleteRemoves() async throws {
		try await TG.withAgent { agent in
			let vm = try await TGVM.alpine("login-rename", on: agent)
			try await agent.api.setStartPolicy(vm: vm.name, policy: Self.atLogin)
			let old = TGLaunchd.plistPath(agent.scope, "login-rename")
			#expect(FileManager.default.fileExists(atPath: old))
			try await agent.api.renameVM(named: "login-rename", to: "login-renamed")
			let new = TGLaunchd.plistPath(agent.scope, "login-renamed")
			#expect(!FileManager.default.fileExists(atPath: old))
			let job = try TGLaunchd.readPlist(new)
			#expect(job.label == TGLaunchd.label("login-renamed"))
			#expect(job.arguments.contains("login-renamed"))
			#expect(!job.arguments.contains("login-rename"))
			try await agent.api.deleteVM(named: "login-renamed")
			#expect(!FileManager.default.fileExists(atPath: new))
		}
	}
}
