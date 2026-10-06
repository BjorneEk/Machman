//
//  EngineAgentMenuTests.swift
//  MachmanLabTests
//
//  L2 — the agent menu's Start (P23): a MAC conflict asks and Start Anyway starts, a failed
//  start says so in an alert naming the VM and the reason, and while that alert is up the
//  daemon keeps serving the desktop. Menu items come through the lab control socket under
//  the menu's own enabled rule; the alerts are answered from the answers file and logged.
//  The "dimmed during a macOS install" half is Deferred: macOS (its rule is L1).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — agent menu", .serialized, .enabled(if: Lab.runs(.l2)))
struct EngineAgentMenuTests {
	/// A stopped VM whose only disk is an image file that is gone: its start fails.
	static func brokenVM(_ agent: LabAgent, _ name: String) async throws {
		let api = agent.api
		let info = try await api.createVM(template: .blank)
		try await api.renameVM(named: info.name, to: name)
		try await api.setHardware(
			vm: name, cpuCount: 1, memoryBytes: 1 << 30, nestedVirtualization: nil)
		let image = agent.scope.imagesDir + "/\(name)-gone.img"
		FileManager.default.createFile(atPath: image, contents: Data(count: 1 << 20))
		try await api.addDisk(vm: name, .image(path: image))
		try FileManager.default.removeItem(atPath: image)
	}

	@Test("W3-47: the agent's Start on a MAC conflict asks, and Start Anyway starts the VM")
	func macConflictStartAnyway() async throws {
		let options = LabAgent.Options(answers: ["agent.macConflict": "Start Anyway"])
		try await Lab.withAgent(options) { agent in
			let spec = LabVMSpec(name: "mac-owner", boot: .alpine(), network: true)
			try await agent.withVM(spec, start: false) { vm in
				let twin = try await agent.api.copyVM(
					vm: vm.name, newName: "mac-twin", diskIDs: nil, mountIDs: nil,
					regenerateMAC: false)
				#expect(twin.macAddress == (try await vm.info().macAddress))
				try await vm.start()
				let mark = LabLog.mark()
				#expect(try await SeamProbe.control(agent, "menu start mac-twin") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.macConflict", "Start Anyway$"), after: mark,
					process: "MachmanAgent", timeout: .seconds(30))
				try await TFWait.state(agent.api, "mac-twin", .running, timeout: .seconds(30))
				_ = try await TFVM.recordHost(agent, "mac-twin")
				await TFVM.forceStop(agent, "mac-twin")
				try await agent.api.deleteVM(named: "mac-twin")
			}
		}
	}

	@Test("W3-47: a failed agent start logs an alert naming the VM and the reason")
	func failedStartAlerts() async throws {
		try await Lab.withAgent { agent in
			try await Self.brokenVM(agent, "broken-start")
			let mark = LabLog.mark()
			#expect(try await SeamProbe.control(agent, "menu start broken-start") == "ok")
			let prompt = try await LabLog.waitFor(
				SeamProbe.promptLine("agent.actionFailed", "OK"), after: mark,
				process: "MachmanAgent", timeout: .seconds(60))
			#expect(prompt.eventMessage.contains("Couldn’t start “broken-start”"))
			let reason = try await LabLog.waitFor(
				"Couldn’t start “broken-start”: ", after: mark, process: "MachmanAgent")
			let said = reason.eventMessage.components(
				separatedBy: "Couldn’t start “broken-start”: ")
			#expect(said.count == 2 && !said[1].isEmpty)
			#expect(!reason.eventMessage.contains("MachmanError("))
			#expect(try await agent.api.vm(named: "broken-start").state != .running)
			try await agent.api.deleteVM(named: "broken-start")
		}
	}

	@Test("W3-58: while a failed start's alert is up, the agent keeps serving starts and stops")
	@MainActor
	func servesBehindHeldAlert() async throws {
		let hold = 20
		let options = LabAgent.Options(
			answers: ["agent.actionFailed": ["button": "OK", "holdSeconds": hold]])
		try await Lab.withAgent(options) { agent in
			try await Self.brokenVM(agent, "failed-start")
			try await agent.withVM(
				LabVMSpec(name: "served-meanwhile", boot: .alpine()), start: false
			) { vm in
				let desktop = try await TFDesktop.make(agent: agent)
				let mark = LabLog.mark()
				#expect(try await SeamProbe.control(agent, "menu start failed-start") == "ok")
				_ = try await LabLog.waitFor(
					SeamProbe.promptLine("agent.actionFailed", "OK \\(held \(hold) s\\)"),
					after: mark, process: "MachmanAgent", timeout: .seconds(60))
				let t0 = ContinuousClock.now
				// Behind the held alert: the desktop lists, starts and stops another VM.
				try await desktop.waitForList()
				desktop.viewModel.startVM(vm.name, headless: true)
				try await desktop.waitForEntry(vm.name, "running", timeout: .seconds(15)) {
					$0.state == .running
				}
				_ = try await TFVM.recordHost(agent, vm.name)
				desktop.viewModel.stopVM(vm.name, mode: .force)
				try await desktop.waitForEntry(vm.name, "stopped", timeout: .seconds(15)) {
					$0.state == .stopped
				}
				TFVM.forget(agent, vm.name)
				#expect(try await agent.control("ping") == "ok")
				#expect(ContinuousClock.now - t0 < .seconds(hold - 2))
				#expect(desktop.viewModel.presentedError == nil)
				await desktop.close()
				try await agent.api.deleteVM(named: "failed-start")
			}
		}
	}
}
