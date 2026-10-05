//
//  EngineSkewTests.swift
//  MachmanLabTests
//
//  L2 — two versions of Machman on one Mac (X7, E22, E32): an OLDER copy of this build
//  (patched version, ad hoc; TFBuilds) serves, and this build's agent replaces it as a newer
//  agent would — answering the replace prompt from the answers file — and adopts its running
//  VMs, whose vmhosts are then older than their agent. Plus a vmhost started as its autostart
//  job starts it, and a too-old agent as the desktop's connect loop meets it. The desktop's
//  own prompts (the too-old alert, the stale-Replace guard) live in DaemonConnection
//  (r3-3a): only the values they show are asserted here (Deferred: seam).
//

import AppKit
import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopCore

@Suite("Engine — version skew", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineSkewTests {
	/// An older copy serves `scope`; `body` gets it after its VMs (one per name) started.
	/// Then this build's agent takes over (Replace) and `takeover` gets its connection.
	static func takeover(
		vms: [String],
		_ takeover: (LabAgent, RemoteMachman, pid_t, String, UInt64) async throws -> Void
	) async throws {
		let older = TFBuilds.olderVersion(than: TFBuilds.current)
		let app = try await TFBuilds.agentApp(older)
		let options = LabAgent.Options(answers: ["agent.replaceOlder": "Replace"], appURL: app)
		try await Lab.withAgent(options) { agent in
			#expect(agent.bundleVersion == older)
			#expect(agent.api.hello.daemonVersion == older)
			for name in vms {
				let vm = try await LabVM.create(LabVMSpec(name: name, boot: .alpine()), on: agent)
				try await vm.start()
			}
			let oldPid = agent.pid
			let mark = LabLog.mark()
			let newPid = try await TFAgents.launchSecond(scope: agent.scope)
			var api: RemoteMachman?
			defer {
				let held = api
				Task { await TFAgents.stopSecond(pid: newPid, api: held, scope: agent.scope) }
			}
			api = try await TFAgents.connectAfterTakeover(
				newPid: newPid, oldPid: oldPid, socketPath: agent.socketPath)
			try await takeover(agent, api!, newPid, older, mark)
			for name in vms {
				let pidName = TFVM.pidName(scope: agent.scope, vm: name)
				let host = LabProcesses.pids(kind: "vmhost", namePrefix: pidName).first
				try? await api!.stop(vm: name, mode: .force)
				if let host { _ = await LabProcesses.waitForExit(host, timeout: .seconds(30)) }
				LabProcesses.removePid(kind: "vmhost", name: pidName)
				try? await api!.deleteVM(named: name)
			}
			await TFAgents.stopSecond(pid: newPid, api: api, scope: agent.scope)
		}
		await TFBuilds.unregisterAll()
	}

	@Test("16a: a current agent replaces an older one and re-adopts its running VM")
	func currentReplacesOlder() async throws {
		try await Self.takeover(vms: ["x7"]) { agent, api, newPid, _, _ in
			#expect(api.hello.daemonVersion == TFBuilds.current)
			#expect(api.peerPID == newPid)
			let host = try #require(
				LabProcesses.pids(kind: "vmhost", namePrefix: "\(agent.scope.id)-x7").first)
			let info = try await TFWait.vm(api, "x7", "re-adopted", timeout: .seconds(30)) {
				$0.state == .running && !$0.isUnresponsive
			}
			#expect(info.state == .running)
			#expect(try await TFVM.peer("x7") == host)
			let path = try #require(info.consolePorts?.first?.socketPath)
			let console = try await LabConsole.connect(path, transcript: "\(agent.scope.id)-x7")
			defer { console.close() }
			try await console.expect("LAB-READY", timeout: .seconds(20))
		}
	}

	@Test("W4-20: the replace prompt names both versions and Replace keeps the VM running")
	func replacePromptNamesVersions() async throws {
		try await Self.takeover(vms: ["x7-prompt"]) { _, api, newPid, older, mark in
			let current = TFBuilds.current
			let prompt = try await LabLog.waitFor(
				SeamProbe.promptLine("agent.replaceOlder", "Replace$"), after: mark,
				process: "MachmanAgent")
			#expect(prompt.processID == Int(newPid))
			#expect(prompt.eventMessage.contains("An older Machman Agent is still running"))
			let replacing = try await LabLog.waitFor(
				"replacing daemon " + NSRegularExpression.escapedPattern(
					for: "\(older) with \(current)"), after: mark, process: "MachmanAgent")
			#expect(replacing.processID == Int(newPid))
			#expect(try await api.vm(named: "x7-prompt").state == .running)
		}
	}

	@Test("W3-15: an older vmhost's VM refuses settings until it restarts")
	func olderHostRefusesSettings() async throws {
		try await Self.takeover(vms: ["e22-a", "e22-b"]) { agent, api, _, _, _ in
			let sentence = "Restart this VM to finish updating"
			for name in ["e22-a", "e22-b"] {
				let info = try await TFWait.vm(api, name, "outdated", timeout: .seconds(30)) {
					$0.outdatedHost == true
				}
				#expect(info.restartToUpdate == sentence)
			}
			do {
				try await api.setHardware(
					vm: "e22-a", cpuCount: 2, memoryBytes: nil, nestedVirtualization: nil)
				Issue.record("an outdated vmhost took a setting change")
			} catch let error as MachmanError {
				#expect(error.message == "Restart e22-a to finish updating")
			}
			let oldHost = LabProcesses.pids(
				kind: "vmhost", namePrefix: TFVM.pidName(scope: agent.scope, vm: "e22-a")).first
			try await api.stop(vm: "e22-a", mode: .force)
			try await TFWait.state(api, "e22-a", .stopped, timeout: .seconds(30))
			if let oldHost { _ = await LabProcesses.waitForExit(oldHost, timeout: .seconds(30)) }
			try await api.start(vm: "e22-a", options: StartOptions(openWindow: false))
			try await TFWait.state(api, "e22-a", .running, timeout: .seconds(60))
			let host = try await RemoteMachman(
				socketPath: MachmanPaths.vmSocketPath(vm: "e22-a"), clientName: "machman-lab-tf")
			#expect(host.hello.daemonVersion == "\(TFBuilds.current)-vmhost")
			if let pid = host.peerPID {
				try LabProcesses.writePid(
					pid, kind: "vmhost", name: TFVM.pidName(scope: agent.scope, vm: "e22-a"))
			}
			await host.disconnect()
			let restarted = try await api.vm(named: "e22-a")
			#expect(restarted.outdatedHost == nil)
			#expect(restarted.restartToUpdate == nil)
			#expect(try await api.vm(named: "e22-b").restartToUpdate == sentence)
			try await api.setHardware(
				vm: "e22-a", cpuCount: 2, memoryBytes: nil, nestedVirtualization: nil)
			#expect(try await api.vm(named: "e22-a").cpuCount == 2)
		}
	}
}
