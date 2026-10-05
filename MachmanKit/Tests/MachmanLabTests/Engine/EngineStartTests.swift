//
//  EngineStartTests.swift
//  MachmanLabTests
//
//  L2 — what a start refuses and says: a setting change during a start (E19), the devices a
//  start leaves out with one warning each (E9 uart and display, W3 trackpad), and the one
//  "started" a headless start announces (E9). The desktop half runs the app's own view model
//  over the lab agent.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — starts", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineStartTests {
	@Test(
		"""
		W1-20: a setting change during a start is refused as starting, then applies and \
		survives a restart
		""")
	func settingDuringStart() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(LabVMSpec(name: "e19", boot: .alpine()), start: false) { vm in
				let socket = MachmanPaths.vmSocketPath(vm: "e19")
				var refusal: MachmanError?
				for attempt in 1...3 {
					let api = agent.api
					let start = Task {
						try await api.start(vm: "e19", options: StartOptions(openWindow: false))
					}
					// The start is under way once its vmhost serves; the change goes then.
					let sent = ContinuousClock.now
					while !FileManager.default.fileExists(atPath: socket),
						ContinuousClock.now - sent < .seconds(5) {
						try await Task.sleep(for: .milliseconds(5))
					}
					do {
						try await api.setHardware(
							vm: "e19", cpuCount: 2, memoryBytes: nil, nestedVirtualization: nil)
					} catch let error as MachmanError {
						refusal = error
					}
					try await start.value
					try await vm.waitForState(.running, timeout: .seconds(60))
					_ = try await TFVM.recordHost(agent, "e19")
					if refusal != nil { break }
					// The start finished first: undo the change and race again.
					MachmanLogger.log(.passiveWarning,
						"lab: W1-20 attempt \(attempt): the start finished before the change")
					await TFVM.forceStop(agent, "e19")
					try await TFVM.settled {
						try await api.setHardware(
							vm: "e19", cpuCount: 1, memoryBytes: nil, nestedVirtualization: nil)
					}
				}
				let error = try #require(refusal, "three setting changes landed outside the start")
				#expect(error.code == .invalidState)
				#expect(error.message == "e19 is starting — try again once it is running")
				try await agent.api.setHardware(
					vm: "e19", cpuCount: 2, memoryBytes: nil, nestedVirtualization: nil)
				#expect(try await vm.info().cpuCount == 2)
				await TFVM.forceStop(agent, "e19")
				try await vm.start()
				#expect(try await vm.info().cpuCount == 2)
			}
		}
	}

	@Test(
		"W3-13: a VM with a UART port starts without it and warns once",
		.enabled(if: TFGate.uartGated, TFGate.uartReason))
	func uartDroppedOnce() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "e9-uart", boot: .alpine())
			try await agent.withVM(spec, start: false) { vm in
				try await agent.api.addUartPort(vm: vm.name)
				let events = await TFEvents(api: agent.api)
				defer { events.stop() }
				try await vm.start()
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				try await Task.sleep(for: .seconds(1))
				let warnings = events.logs(vm: vm.name, level: .warning).filter {
					$0.hasPrefix("Since macOS") && $0.hasSuffix("so VMs start without them.")
				}
				#expect(warnings.count == 1)
				let info = try await vm.info()
				#expect(info.state == .running)
				#expect(info.uartPorts?.count == 1)
				#expect(info.uartPorts?.first?.unavailable?.reason == .privateUARTGated)
			}
		}
	}

	@Test("W3-13: a display-less VM started with Open window on starts headless and says so")
	func displaylessStartsHeadless() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			let events = await TFEvents(api: agent.api)
			defer { events.stop() }
			let spec = LabVMSpec(name: "e9-head", boot: .alpine())
			try await agent.withVM(spec, start: false) { vm in
				try await TFVM.start(agent, vm.name, options: StartOptions(openWindow: true))
				let sentence = "It has no display, so it started headless."
				try await events.waitFor("the headless warning", timeout: .seconds(10)) {
					$0 == .log(vm: "e9-head", level: .warning, message: sentence)
				}
				try await desktop.toasts.waitFor("e9-head: \(sentence)", timeout: .seconds(10))
				try await Task.sleep(for: .seconds(2))
				#expect(events.logs(vm: vm.name, level: .warning).filter { $0 == sentence }.count
					== 1)
				#expect(desktop.toasts.count(equal: "e9-head: \(sentence)") == 1)
				#expect(try await vm.info().windowOpen == false)
			}
			await desktop.close()
		}
	}

	@Test("W3-64a: a headless start announces the VM started exactly once")
	func headlessStartAnnouncedOnce() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			let spec = LabVMSpec(name: "e9-once", boot: .alpine())
			try await agent.withVM(spec, start: false) { vm in
				try await desktop.waitForList()
				desktop.viewModel.startVM(vm.name, headless: true)
				try await vm.waitForState(.running, timeout: .seconds(60))
				_ = try await TFVM.recordHost(agent, vm.name)
				try await desktop.toasts.waitFor("e9-once started", timeout: .seconds(10))
				try await Task.sleep(for: .seconds(3))
				#expect(desktop.toasts.count(equal: "e9-once started") == 1)
			}
			await desktop.close()
		}
	}

	@Test("W4-16: a Linux VM with the Mac trackpad warns once, naming the VM once")
	func trackpadOnLinuxWarnsOnce() async throws {
		try await Lab.withAgent { agent in
			let name = "w3-pad"
			try await agent.withVM(LabVMSpec(name: name, boot: .alpine()), start: false) { _ in
				// A Linux VM with the trackpad on: no edit allows it any more, so the config
				// is written by hand as an older Machman (or a macOS-boot switch) left it.
				try await TFAgents.restartForEdit(agent) {
					try TFVM.editConfig(dir: TFVM.dir(agent, name)) { config in
						var devices = config["devices"] as? [[String: Any]] ?? []
						devices.append(["kind": "trackpad", "enabled": true])
						config["devices"] = devices
					}
				}
				let devices = try await agent.api.vm(named: name).devices ?? []
				try #require(devices.contains { $0.kind == .trackpad })
				let desktop = try await TFDesktop.make(agent: agent)
				let events = await TFEvents(api: agent.api)
				defer { events.stop() }
				try await TFVM.start(agent, name)
				let sentence = "The Mac trackpad needs a macOS guest, so it isn’t attached."
				try await events.waitFor("the trackpad warning", timeout: .seconds(10)) {
					$0 == .log(vm: name, level: .warning, message: sentence)
				}
				try await desktop.toasts.waitFor("\(name): \(sentence)", timeout: .seconds(10))
				try await Task.sleep(for: .seconds(2))
				let warned = events.logs(vm: name, level: .warning).filter { $0 == sentence }
				#expect(warned.count == 1)
				#expect(desktop.toasts.count(equal: "\(name): \(sentence)") == 1)
				let entries = desktop.viewModel.activity.entries.filter {
					$0.vm == name && $0.detail == sentence
				}
				#expect(entries.count == 1)
				await desktop.close()
			}
		}
	}
}
