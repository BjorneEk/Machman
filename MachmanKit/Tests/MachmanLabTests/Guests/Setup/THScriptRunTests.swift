//
//  THScriptRunTests.swift
//  MachmanLabTests
//
//  L3 — unattended installer runs, each on a fresh guest: `-y --two-way` sets everything up
//  (the Mac's key, sshd, `ssh mac` through the lab sshd once approved, the report), and
//  `--uninstall` takes back exactly what carries the VM's marker.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

enum THScriptRuns {
	/// The guests the unattended rows run on.
	static let kinds: [THGuestKind] = [.debian, .alpine]

	/// Where a run leaves marked files ("/home/": followed where it is a link).
	static func markedTrees(_ kind: THGuestKind) -> String {
		kind.isLinux ? "/etc /home/ /root" : "/etc /home/ /root /usr/local/etc"
	}

	/// Files under the marked trees that carry `marker`, sorted.
	static func marked(_ g: any THGuest, _ marker: String) async throws -> [String] {
		try await g.check(
			"grep -rlF \(marker) \(markedTrees(g.kind)) 2>/dev/null | LC_ALL=C sort; true")
			.split(separator: "\n").map(String.init)
			.filter { !$0.isEmpty && !$0.hasSuffix("_history") }
	}

	/// The unmarked shared files an uninstall names as kept (FreeBSD's kld_list in
	/// /etc/rc.conf keeps virtio_console: the console devices stay).
	static func keptByUninstall(_ output: String) -> [String] {
		output.contains("kld_list keeps virtio_console") ? ["/etc/rc.conf"] : []
	}

	/// lab's home as the guest resolves it (a link-free path: FreeBSD's /usr/home/lab).
	static func labHome(_ g: any THGuest) async throws -> String {
		try await g.check("cd ~lab && pwd -P")
	}

	/// A setup run as lab with the family's escalation, stdin closed: no question asked.
	static func setUp(_ g: any THGuest, _ arguments: String) async throws
		-> (status: Int32, output: String) {
		try await g.install(arguments, user: "lab", escalation: g.kind.escalation)
	}

	/// The prompts an unattended run must never print.
	static let questions = ["Proceed?", "[Y/n]", "[y/N]", "Choose [", "Toggle numbers"]

	/// The Mac's key (host_key.pub of the payload) as authorized_keys carries it.
	static func macKey(_ g: any THGuest) throws -> String {
		try String(contentsOfFile: g.vm.payloadDir + "/host_key.pub", encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// ssh -G's answer for `alias` as `user` (no connection): hostname and user.
	static func resolve(_ g: any THGuest, _ alias: String, user: String) async throws
		-> [String: String] {
		let out = try await g.check("ssh -G \(alias)", user: user)
		var values: [String: String] = [:]
		for line in out.split(separator: "\n") {
			let words = line.split(separator: " ", maxSplits: 1).map(String.init)
			if words.count == 2, values[words[0]] == nil { values[words[0]] = words[1] }
		}
		return values
	}

	/// The guest's default gateway (its "Mac").
	static func gateway(_ g: any THGuest) async throws -> String {
		g.kind.isLinux
			? try await g.check("ip -4 route show default | awk '{ print $3; exit }'")
			: try await g.check("route -n get default | awk '/gateway:/ { print $2; exit }'")
	}
}

// L3 — Guest Setup run unattended on fresh guests (one boot per case).
@Suite("L3 Guest Setup — unattended runs", .serialized, .enabled(if: Lab.runs(.l3)))
struct THScriptRunTests {
	@Test(
		"S4: -y --two-way sets up sshd, the Mac's key, ssh mac and the report",
		arguments: THScriptRuns.kinds)
	func s4(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			let started = try await g.reportMark()
			let run = try await THScriptRuns.setUp(g, "-y --two-way")
			#expect(run.status == 0, "\(run.output)")
			for question in THScriptRuns.questions {
				#expect(!run.output.contains(question), "asked '\(question)':\n\(run.output)")
			}
			#expect(try await g.sh(THFacts.sshdActive(kind)).status == 0, "sshd runs")
			#expect(try await g.sh(THFacts.sshdEnabled(kind)).status == 0, "sshd is enabled")
			let marker = try g.marker()
			let key = try THScriptRuns.macKey(g)
			let home = try await THScriptRuns.labHome(g)
			let keys = try await g.check("cat \(home)/.ssh/authorized_keys")
			#expect(keys.split(separator: "\n").contains {
				$0.trimmingCharacters(in: .whitespaces) == key
			}, "\(keys)")
			#expect(key.contains(" \(marker) "), "the Mac's key carries the marker: \(key)")
			// `ssh mac`: Machman's block leads lab's config and names the gateway as the Mac.
			let first = try await g.check(
				"grep -v -e '^#' -e '^[[:space:]]*$' \(home)/.ssh/config | head -n 1")
			#expect(first == "Host mac", "\(first)")
			let gateway = try await THScriptRuns.gateway(g)
			let mac = try await THScriptRuns.resolve(g, "mac", user: "lab")
			#expect(mac["hostname"] == gateway)
			#expect(mac["user"] == NSUserName())

			let setup = try await g.waitForReport(newerThan: started)
			#expect(setup.lastRunStatus == GuestRunStatus.ok, "\(setup)")
			let info = try await g.vm.info()
			#expect(info.ssh?.configured == true)
			#expect(info.ssh?.guestUser == "lab")
			#expect(info.ssh?.reverseState == .pending)

			// Approved, the guest's `ssh mac` reaches "the Mac" — the lab sshd behind the
			// redirect, its key pinned.
			guard let labMac = g.mac else {
				TH.log("S4: no lab sshd (the doctor refused a bridge listener): ssh mac skipped")
				return
			}
			try await g.approveReverse()
			let logins = labMac.acceptedLogins.count
			let ssh = try await g.sh("ssh -o BatchMode=yes mac true", user: "lab")
			#expect(ssh.status == 0, "\(ssh.output)")
			#expect(await labMac.waitForLogins(moreThan: logins),
				"the lab sshd saw no login:\n\(labMac.log(containing: "").suffix(15))")
		}
	}

	@Test(
		"S7: --uninstall removes only marked artifacts and keeps owners and modes",
		arguments: THScriptRuns.kinds)
	func s7(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			let pristine = try await THGuestFiles.fingerprint(g)
			let run = try await THScriptRuns.setUp(g, "-y --two-way")
			#expect(run.status == 0, "\(run.output)")
			let marker = try g.marker()
			let marked = try await THScriptRuns.marked(g, marker)
			#expect(!marked.isEmpty, "the setup left marked files")
			var stats: [String: THGuestFiles.Stat] = [:]
			for path in marked { stats[path] = try await THGuestFiles.stat(g, path) }
			// The user's ssh config becomes a link to a copy: a file the uninstall may not edit.
			let home = try await THScriptRuns.labHome(g)
			let config = "\(home)/.ssh/config"
			let real = "\(home)/th-config.real"
			try await g.check(
				"cp -p \(config) \(real) && rm \(config) && ln -s \(real) \(config)"
					+ " && chown -h lab:lab \(config)")
			let linked = try await g.check("cat \(real)")

			let uninstall = try await g.install(
				"--uninstall -y", user: "lab", escalation: kind.escalation)
			#expect(uninstall.status == 4, "kept lines make it partial:\n\(uninstall.output)")
			let notes = uninstall.output.split(separator: "\n").filter {
				$0.contains("/lab/.ssh/config is a symbolic link")
			}
			#expect(notes.count == 1, "\(uninstall.output)")
			let still = try await THScriptRuns.marked(g, marker)
			let why = "only the link's target keeps the marker: \(still)\n\(uninstall.output)"
			#expect(still == [real], Comment(rawValue: why))
			#expect(try await g.check("cat \(real)") == linked, "the link's target is untouched")
			for path in marked where path != config {
				guard try await g.sh("test -f \(ShellQuote.single(path))").status == 0 else {
					continue
				}
				#expect(try await THGuestFiles.stat(g, path) == stats[path], "\(path)")
			}
			#expect(try await g.sh(THFacts.sshdEnabled(kind)).status == 0, "sshd stays enabled")
			// Everything else is as before the setup: what Machman created and removed again,
			// the marked files and the link aside.
			let after = try await THGuestFiles.fingerprint(g)
			let changed = try await THGuestFiles.changes(
				g, from: pristine, to: after,
				ignoring: marked + [real, config] + THScriptRuns.keptByUninstall(uninstall.output))
			#expect(changed.isEmpty, "unmarked files changed:\n\(changed)")
		}
	}
}
