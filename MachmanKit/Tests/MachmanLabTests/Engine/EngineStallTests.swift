//
//  EngineStallTests.swift
//  MachmanLabTests
//
//  L2 — a vmhost that stops answering (SIGSTOP stands in for a hung process): its VM reads
//  Not responding while the rest of the list keeps working (E20), and the desktop refuses a
//  Shut Down at once and ends the process only when asked (E36). Every SIGSTOP is paired
//  with a SIGCONT in a defer, and only ever reaches a lab vmhost (TFProcess).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanUI
@testable import MachmanDesktopCore

@Suite("Engine — stalled vmhosts", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineStallTests {
	@Test("W1-21: a stopped vmhost reads not responding within 10 s while the other VM updates")
	func stalledHostReadsNotResponding() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			try await agent.withVM(LabVMSpec(name: "stalled", boot: .alpine())) { a in
				try await agent.withVM(LabVMSpec(name: "healthy", boot: .alpine())) { b in
					try await desktop.waitForEntry("healthy", "running", timeout: .seconds(10)) {
						$0.state == .running
					}
					// The VM to stall is selected: its preview polls (the app's 4 s cadence).
					desktop.showPreviews(of: ["stalled"])
					let host = try await a.hostPID()
					try #require(TFProcess.stop(host))
					var stopped = true
					defer { if stopped { TFProcess.resume(host) } }
					let api = agent.api
					let stalledAt = ContinuousClock.now
					try await desktop.waitForEntry(
						"stalled", "not responding", timeout: .seconds(20)
					) { $0.isUnresponsive }
					#expect(ContinuousClock.now - stalledAt <= .seconds(13))
					#expect(try await a.info().isUnresponsive)
					#expect(try await b.info().state == .running)
					#expect(try await b.info().isUnresponsive == false)
					// The other VM keeps updating: its stop lands while stalled stays stalled.
					try await api.stop(vm: "healthy", mode: .force)
					try await TFWait.state(api, "healthy", .stopped, timeout: .seconds(10))
					#expect(try await a.info().isUnresponsive)
					// The desktop's list follows both, with no reload asked for.
					try await desktop.waitForEntry(
						"stalled", "not responding", timeout: .seconds(10)
					) {
						$0.isUnresponsive
					}
					try await desktop.waitForEntry("healthy", "stopped", timeout: .seconds(10)) {
						$0.state == .stopped
					}
					TFVM.forget(agent, "healthy")
					TFProcess.resume(host)
					stopped = false
					try await TFWait.vm(api, "stalled", "answering again", timeout: .seconds(10)) {
						$0.unresponsive == nil && $0.state == .running
					}
					try await desktop.waitForEntry("stalled", "answering", timeout: .seconds(10)) {
						$0.unresponsive == nil
					}
				}
			}
			await desktop.close()
		}
	}

	@Test(
		"""
		R3W2-27: Shut Down on a not-responding VM is refused at once and End Process ends \
		it
		""")
	func endProcessOnRequest() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			try await agent.withVM(LabVMSpec(name: "hung-host", boot: .alpine())) { vm in
				desktop.showPreviews(of: ["hung-host"])
				let host = try await vm.hostPID()
				try #require(TFProcess.stop(host))
				defer { TFProcess.resume(host) }
				try await desktop.waitForEntry(
					"hung-host", "not responding", timeout: .seconds(20)
				) {
					$0.isUnresponsive
				}
				let view = desktop.viewModel
				let asked = ContinuousClock.now
				view.stopVM("hung-host", mode: .soft)
				try await TFWait.until("the shut-down refusal", timeout: .seconds(10)) {
					view.presentedError != nil
				}
				#expect(ContinuousClock.now - asked < .seconds(3))
				#expect(
					view.presentedError?.message == "hung-host is not responding — use Force Stop")
				view.isErrorPresented = false
				// Force Stop asks first: the process is ended only on the answer.
				view.stopVM("hung-host", mode: .force)
				#expect(view.pendingEndProcess?.vm == "hung-host")
				#expect(view.pendingEndProcess?.prompt == EndProcessPrompt.forVM("hung-host"))
				view.isEndProcessPresented = false
				try await Task.sleep(for: .seconds(1))
				#expect(view.vms.contains { $0.name == "hung-host" })
				#expect(LabProcesses.isAlive(host))
				view.stopVM("hung-host", mode: .force)
				#expect(view.pendingEndProcess != nil)
				view.isEndProcessPresented = false
				view.endProcess("hung-host")
				try await desktop.waitForEntry("hung-host", "stopped", timeout: .seconds(15)) {
					$0.state == .stopped
				}
				let ended = "hung-host: Its process wasn’t answering, so Machman ended it."
				try await desktop.toasts.waitFor(ended, timeout: .seconds(10))
				#expect(await LabProcesses.waitForExit(host, timeout: .seconds(10)))
				TFVM.forget(agent, "hung-host")
			}
			await desktop.close()
		}
	}
}
