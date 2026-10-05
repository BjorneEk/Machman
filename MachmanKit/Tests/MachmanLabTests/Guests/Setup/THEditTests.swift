//
//  THEditTests.swift
//  MachmanLabTests
//
//  L3 — the user's own files around a setup run: a look-alike key stays, a report the guest
//  points at /dev/zero or a FIFO leaves the vmhost and the agent answering, and a user's own
//  `Host mac` stays theirs while Machman's block leads a config that opens with `Host *`.
//

import Foundation
import MachmanAPI
import MachmanClient
import Testing

enum THEdits {
	/// Within `seconds`, both the vmhost (on its own socket) and the agent answer about `vm`.
	static func answers(_ g: any THGuest, within seconds: Int) async -> Bool {
		let name = g.vm.name
		let agent = g.agent
		return await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				do {
					let host = try await RemoteMachman(
						socketPath: MachmanPaths.vmSocketPath(vm: name),
						clientName: "machman-lab-th-probe")
					defer { Task { await host.disconnect() } }
					_ = try await host.listVMs()
					_ = try await agent.api.vm(named: name)
					return true
				} catch {
					return false
				}
			}
			group.addTask {
				try? await Task.sleep(for: .seconds(seconds))
				return false
			}
			let first = await group.next() ?? false
			group.cancelAll()
			return first
		}
	}

	/// For `seconds`, every 2 s: both answer within 5 s and lastReportAt stays `report`.
	static func staysResponsive(_ g: any THGuest, seconds: Int, report: Date?) async throws {
		let deadline = ContinuousClock.now + .seconds(seconds)
		while ContinuousClock.now < deadline {
			#expect(await answers(g, within: 5), "the vmhost or the agent stopped answering")
			#expect(try await g.vm.info().setup?.lastReportAt == report)
			try await Task.sleep(for: .seconds(2))
		}
	}
}

// L3 — the user's own files around setup runs on Debian.
@Suite("L3 Guest Setup — the user's own files", .serialized, .enabled(if: Lab.runs(.l3)))
struct THEditTests {
	@Test("R3W2-17: a look-alike bob@machman key in authorized_keys stays")
	func lookAlikeKeyStays() async throws {
		try await TH.withGuest(.debian) { g in
			let bob = try await THClones.addUsersOwnKey(g, comment: "bob@machman-debian")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let run = try await g.install("-y --ssh", user: "lab", escalation: .sudo)
			#expect(run.status == 0, "\(run.output)")
			let keys = try await g.check("cat /home/lab/.ssh/authorized_keys")
			#expect(keys.split(separator: "\n").map(String.init).contains(bob), "\(keys)")
			#expect(!TH.unwrapped(run.output).contains("removed another Machman VM's key"),
				"\(run.output)")
		}
	}

	@Test("R3W2-18: a report linked to /dev/zero or a FIFO leaves the vmhost responsive")
	func hostileReportLeavesHostResponsive() async throws {
		try await TH.withGuest(.debian) { g in
			let started = try await g.reportMark()
			let run = try await g.install("-y --ssh", user: "lab", escalation: .sudo)
			#expect(run.status == 0, "\(run.output)")
			let report = try await g.waitForReport(newerThan: started).lastReportAt
			let guestReport = GuestPaths.share + "/GuestReport/report.env"
			try await g.check("ln -sf /dev/zero \(guestReport)")
			try await THEdits.staysResponsive(g, seconds: 20, report: report)
			// A FIFO: made in the guest where virtiofs lets it, else by the host in its place.
			try await g.check("rm -f \(guestReport)")
			let fifo = try await g.sh("mkfifo \(guestReport)")
			if fifo.status != 0 {
				TH.log("R3W2-18: virtiofs refused mkfifo (\(fifo.output)); the host makes it")
				#expect(mkfifo(g.vm.reportFile, 0o644) == 0)
			} else {
				TH.log("R3W2-18: the guest made the FIFO")
			}
			try await THEdits.staysResponsive(g, seconds: 20, report: report)
			try await g.check("rm -f \(guestReport)")
			// A run that changes the outcome (the host restamps only new content) is taken.
			let again = try await g.reportMark()
			let rerun = try await g.install(
				"-y --ssh --two-way", user: "lab", escalation: .sudo)
			#expect(rerun.status == 0, "\(rerun.output)")
			try await g.waitForReport(newerThan: again)
		}
	}

	@Test("R3W2-20: a user's Host mac stays theirs; after Host * Machman's block leads")
	func usersHostMacStays() async throws {
		try await TH.withGuest(.debian) { g in
			try await g.check(
				"mkdir -p -m 700 /home/lab/.ssh && printf 'Host mac\\n\\tHostName studio.lan\\n'"
					+ " > /home/lab/.ssh/config && chown -R lab /home/lab/.ssh")
			let own = try await g.install("-y --two-way", user: "lab", escalation: .sudo)
			#expect(own.status == 0, "\(own.output)")
			let said = TH.unwrapped(own.output)
			#expect(said.contains("'ssh mac' stays your own entry"), "\(own.output)")
			#expect(!said.contains("guest -> host ready"), "\(own.output)")

			try await g.check(
				"useradd -m -s /bin/sh lab2 && mkdir -p -m 700 /home/lab2/.ssh && printf"
					+ " 'Host *\\n\\tUser me\\n' > /home/lab2/.ssh/config"
					+ " && chown -R lab2 /home/lab2/.ssh")
			let after = try await g.install("-y --two-way --user lab2")
			#expect(after.status == 0, "\(after.output)")
			#expect(TH.unwrapped(after.output).contains("guest -> host ready"), "\(after.output)")
			let first = try await g.check(
				"grep -v -e '^[[:space:]]*$' /home/lab2/.ssh/config | head -n 2")
			#expect(first.hasPrefix("# BEGIN \(try g.marker())"), "\(first)")
			#expect(first.hasSuffix("Host mac"), "\(first)")
			let gateway = try await THScriptRuns.gateway(g)
			let mac = try await THScriptRuns.resolve(g, "mac", user: "lab2")
			#expect(mac["hostname"] == gateway)
			#expect(mac["user"] == NSUserName())
		}
	}
}
