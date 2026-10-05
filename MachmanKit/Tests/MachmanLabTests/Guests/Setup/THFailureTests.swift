//
//  THFailureTests.swift
//  MachmanLabTests
//
//  L3 — a first run that fails, and the toasts runs make: a package that cannot be installed
//  (the guest reaches no mirror: its network is the lab's) fails the run in one sentence that
//  the report carries, and the installer stays served after a restart; the desktop's view
//  model toasts once per changed run, never at a boot, and says when setup was removed.
//

import Foundation
import MachmanAPI
import Testing

// L3 — failed runs and setup toasts on Debian (the desktop's view model on the lab agent).
@Suite("L3 Guest Setup — failures and toasts", .serialized, .enabled(if: Lab.runs(.l3)))
struct THFailureTests {
	@Test("S6a: with networking down the install fails in one sentence the report carries")
	func failedFirstRun() async throws {
		try await TH.withGuest(.debian) { g in
			let vz = try #require(g as? THVZGuest)
			// No SSH server, and no mirror to install one from (the lab's rules refuse it).
			try await g.check(
				"DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq openssh-server")
			let mark = try await g.reportMark()
			let run = try await g.install("-y --ssh --install", user: "lab", escalation: .sudo)
			#expect(run.status != 0, "\(run.output)")
			let errors = run.output.split(separator: "\n").filter {
				$0.hasPrefix("✗ ") || $0.hasPrefix("[xx] ")
			}.map(String.init)
			#expect(errors.count == 1, "one precise error line:\n\(run.output)")
			#expect(errors.first?.contains("could not install the SSH server") == true,
				"\(run.output)")
			let setup = try await g.waitForReport(newerThan: mark)
			#expect(setup.lastRunStatus == GuestRunStatus.failed, "\(setup)")
			let note = setup.lastRunNote ?? ""
			#expect(note.contains("openssh-server") || note.contains("SSH server"),
				"the inspector's note names the step: \(note)")

			// W2-10: after a restart the installer is served again (the last run failed).
			try await vz.restartFromHost(remount: true)
			#expect(FileManager.default.fileExists(
				atPath: g.vm.payloadDir + "/" + GuestSetupInstallerInfo.scriptName))
			#expect(try await g.sh("test -f \(TH.installerPath)").status == 0)
			let after = try await g.vm.info().setup
			#expect(after?.lastRunStatus == GuestRunStatus.failed, "\(String(describing: after))")
		}
	}

	@Test("W3-46: setup toasts once per changed run, never at boot, and says removed")
	func setupToasts() async throws {
		try await TH.withGuest(.debian) { g in
			let desktop = try await THDesktop.make(on: g.agent)
			let log = desktop.toasts
			defer { Task { await desktop.close() } }
			let name = g.vm.name
			let complete = "\(name): guest setup complete"
			let removed = "\(name): guest setup removed"
			let first = try await g.install(
				"-y --two-way --automount-virtiofs", user: "lab", escalation: .sudo)
			#expect(first.status == 0, "\(first.output)")
			#expect(await log.wait(for: complete, count: 1), "\(log.all)")

			// A reboot sends the report again (the guest writes it; the host takes it in):
			// no toast.
			let written = g.reportFileDate()
			try await g.reboot()
			try await g.waitForReportFile(newerThan: written)
			#expect(log.count(complete) == 1, "a boot toasted: \(log.all)")

			// A re-run whose outcome differs toasts once more: lab's own `Host mac` now
			// follows Machman's block, so the run notes that 'ssh mac' stays theirs (the
			// inspector's "Allow reinstall" serves the installer, should the reboot have been
			// a new run).
			_ = try await g.agent.api.setSetupServed(vm: g.vm.name, serve: true)
			try await (g as? THVZGuest)?.mountShare()
			try await g.check(
				"printf 'Host mac\\n\\tHostName studio.lan\\n' >> /home/lab/.ssh/config")
			let again = try await g.install("-y --two-way", user: "lab", escalation: .sudo)
			#expect(again.status == 0, "\(again.output)")
			#expect(await log.wait(for: complete, count: 2), "\(log.all)")

			let gone = try await g.install("--uninstall -y", user: "lab", escalation: .sudo)
			#expect(gone.status == 0 || gone.status == 4, "\(gone.output)")
			#expect(await log.wait(for: removed, count: 1), "\(log.all)")
			#expect(log.count(complete) == 2, "\(log.all)")
		}
	}
}
