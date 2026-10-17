//
//  EngineGuestSetupTests.swift
//  MachmanLabTests
//
//  L2 — the Guest Setup share as a vmhost serves it: the first boot after an upgrade leaves
//  only the two current directories (G2), a report the guest writes reaches the desktop's
//  list through events, with no reload (G13), and the share serves the script a VM is pinned
//  to, not the build's — from the start, and at once when a running VM is pinned (S67). The
//  guest is the Alpine fixture reading and writing over virtiofs; the setup script itself is
//  L3 (r3-th).
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

@Suite("Engine — guest setup", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineGuestSetupTests {
	@Test(
		"""
		G2: the first boot after an upgrade leaves GuestSetup and GuestReport alone in the \
		share
		""")
	func upgradeSweepsTheShare() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "upgraded", boot: .alpine(), devices: [.guestSetup])
			try await agent.withVM(spec, start: false) { vm in
				let share = TFVM.dir(agent, vm.name) + "/share"
				// What an older Machman left in the share: three superseded payload dirs.
				for old in ["LoginInstaller", "SSHSetup", "SSHReport"] {
					try FileManager.default.createDirectory(
						atPath: share + "/" + old, withIntermediateDirectories: true)
					try "old".write(
						toFile: share + "/\(old)/left-over", atomically: true, encoding: .utf8)
				}
				try await vm.start()
				let entries = try FileManager.default.contentsOfDirectory(atPath: share)
					.filter { !$0.hasPrefix(".") }.sorted()
				#expect(entries == ["GuestReport", "GuestSetup"])
				let payload = try FileManager.default.contentsOfDirectory(
					atPath: share + "/GuestSetup")
				#expect(payload.contains("install.sh"))
			}
		}
	}

	@Test("G13: a report the guest writes reaches the desktop list without a reload")
	func liveReportReachesDesktop() async throws {
		try await Lab.withAgent { agent in
			let desktop = try await TFDesktop.make(agent: agent)
			let events = await TFEvents(api: agent.api)
			defer { events.stop() }
			let spec = LabVMSpec(name: "live-report", boot: .alpine(), devices: [.guestSetup])
			try await agent.withVM(spec) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				try await TFGuest.mountShare(console)
				try await desktop.waitForEntry("live-report", "running", timeout: .seconds(10)) {
					$0.state == .running
				}
				let report = TFReport([
					("SCRIPT_VERSION", "6"), ("STATUS", "ok"), ("USER", "root"),
					("OS_ID", "alpine"), ("FEATURE_console", "configured"),
				])
				try await TFGuest.writeReport(console, report.render())
				let seen = try await desktop.waitForEntry(
					"live-report", "reported", timeout: .seconds(15)
				) {
					$0.ssh?.guestUser == "root" && $0.setup?.lastRunStatus == "ok"
				}
				#expect(seen.setup?.guestOS == "alpine")
				try await events.waitFor("setupChanged", timeout: .seconds(5)) {
					$0 == .setupChanged(vm: "live-report")
				}
			}
			await desktop.close()
		}
	}

	// A script the build never shipped, imported from a file in the scope.
	private static func importScript(
		_ agent: LabAgent, vm: String, marker: String
	) async throws -> (entry: GuestSetupScriptInfo, text: String) {
		let text = "#!/bin/sh\nSCRIPT_VERSION=7\necho \(marker)\n"
		let path = agent.scope.dir + "/\(marker).sh"
		try text.write(toFile: path, atomically: true, encoding: .utf8)
		return (try await agent.api.importSetupScript(path: path, vm: vm), text)
	}

	@Test("S67: a VM pinned to an imported script serves it from its vmhost, not the build's")
	func aPinnedVMServesItsScript() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "pinned", boot: .alpine(), devices: [.guestSetup])
			try await agent.withVM(spec, start: false) { vm in
				let (entry, text) = try await Self.importScript(
					agent, vm: vm.name, marker: "lab-pinned-script")
				#expect(entry.kind == GuestSetupScriptKind.custom)
				#expect(entry.label == "lab-pinned-script.sh" && entry.vm == vm.name)
				let pinned = try await agent.api.setSetupScript(vm: vm.name, id: entry.id)
				#expect(pinned.setup?.servedScript == entry.id)
				let latest = pinned.setup?.scripts?.first { $0.latest == true }
				#expect(latest != nil && latest?.id != entry.id, "\(pinned.setup?.scripts ?? [])")
				try await vm.start()
				let served = TFVM.dir(agent, vm.name) + "/share/GuestSetup/install.sh"
				#expect(try String(contentsOfFile: served, encoding: .utf8) == text)
				#expect(try await agent.api.vm(named: vm.name).setup?.servedScript == entry.id)
			}
		}
	}

	@Test("S67: pinning a running VM swaps the served script in place")
	func pinningARunningVMSwapsTheScript() async throws {
		try await Lab.withAgent { agent in
			let spec = LabVMSpec(name: "swapped", boot: .alpine(), devices: [.guestSetup])
			try await agent.withVM(spec) { vm in
				let console = try await vm.console(0)
				defer { console.close() }
				try await console.expect("LAB-READY", timeout: .seconds(60))
				let share = try await TFGuest.mountShare(console)
				// Its first served start pinned it to this build's script, the latest.
				let first = try await agent.api.vm(named: vm.name).setup
				let latest = first?.scripts?.first { $0.latest == true }?.id
				#expect(latest != nil && first?.servedScript == latest)

				let (entry, text) = try await Self.importScript(
					agent, vm: vm.name, marker: "lab-swapped-script")
				_ = try await agent.api.setSetupScript(vm: vm.name, id: entry.id)
				let served = TFVM.dir(agent, vm.name) + "/share/GuestSetup/install.sh"
				#expect(try String(contentsOfFile: served, encoding: .utf8) == text)
				let seen = try await console.run("cat \(share)/GuestSetup/install.sh")
				#expect(seen.output.contains("lab-swapped-script"), "\(seen.output)")
				#expect(try await agent.api.vm(named: vm.name).setup?.servedScript == entry.id)
			}
		}
	}
}
