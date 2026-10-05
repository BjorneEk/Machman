//
//  THUpdateTests.swift
//  MachmanLabTests
//
//  L3 — an older script's report and the update to this one (v5 from git afbba01, assembled
//  into the run, read-only on the repository), and sysvinit Debian's rc.local: made 0644 with
//  a stale Machman block, the run re-enables it (and says so), and after a reboot it is 0755
//  with every Machman block above exit 0 and the boot report in.
//

import Foundation
import MachmanAPI
import MachmanTestSupport
import Testing

/// The setup script as an older commit assembled it (T29).
enum THOldScript {
	static let revision = "afbba01"

	/// git, when it is a real one: the /usr/bin shim with no developer dir would pop the
	/// Command Line Tools installer.
	static func git() async -> String? {
		let selected = try? await Subprocess.run(
			"/usr/bin/xcode-select", ["-p"], environment: ["PATH": "/usr/bin:/bin"],
			timeout: 30)
		return selected?.status == 0 ? "/usr/bin/git" : nil
	}

	/// install.sh of `revision`, assembled into the run's TH scratch; its SCRIPT_VERSION.
	static func assemble(into dir: String, revision: String = revision) async throws
		-> (path: String, version: Int) {
		guard let git = await git() else {
			throw LabError.specInvalid("no developer dir for git (xcode-select -p)")
		}
		let tree = dir + "/tree"
		try? FileManager.default.removeItem(atPath: tree)
		try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
		let archive = try await Subprocess.run(
			"/bin/sh",
			["-c", "\"$1\" -C \"$2\" archive \"$3\" MachmanKit/Sources/MachmanCore/GuestScripts"
				+ " | tar -x -C \"$4\"", "th-git", git, Lab.repoRoot, revision, tree],
			environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
		guard archive.status == 0 else {
			throw LabError.commandFailed(
				command: "git archive \(revision)", status: archive.status, output: archive.output)
		}
		let out = dir + "/install.sh"
		let built = try await Subprocess.run(
			"/bin/sh",
			[tree + "/MachmanKit/Sources/MachmanCore/GuestScripts/assemble.sh", out],
			environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
		guard built.status == 0 else {
			throw LabError.commandFailed(
				command: "assemble.sh (\(revision))", status: built.status, output: built.output)
		}
		let text = try String(contentsOfFile: out, encoding: .utf8)
		let line = text.split(separator: "\n").first { $0.hasPrefix("SCRIPT_VERSION=") }
		let version = line.flatMap { Int($0.dropFirst("SCRIPT_VERSION=".count)) } ?? -1
		return (out, version)
	}
}

// L3 — script updates and the sysvinit rc.local hook on Debian under VZ.
@Suite("L3 Guest Setup — updates and rc.local", .serialized, .enabled(if: Lab.runs(.l3)))
struct THUpdateTests {
	@Test("W1-25: a v5 report shows the update, and a re-run from the share reports v6")
	func olderReportShowsTheUpdate() async throws {
		var options = THGuestOptions()
		options.mounts = ["th": nil]
		try await TH.withGuest(.debian, options) { g in
			let th = try TH.hostDir(g.agent, "th")
			let old = try await THOldScript.assemble(into: try TH.hostDir(g.agent, "v5"))
			#expect(old.version == 5)
			// The v5 payload: its script beside this run's machman.env and keys.
			let payload = th + "/old/" + GuestSetupInstallerInfo.directoryName
			let manager = FileManager.default
			try manager.createDirectory(atPath: payload, withIntermediateDirectories: true)
			try manager.createDirectory(
				atPath: th + "/old/" + GuestSetupInstallerInfo.reportDirectoryName,
				withIntermediateDirectories: true)
			try manager.copyItem(atPath: old.path, toPath: payload + "/install.sh")
			for name in ["machman.env", "host_key.pub", "host_machine_key.pub"] {
				let source = g.vm.payloadDir + "/" + name
				if manager.fileExists(atPath: source) {
					try manager.copyItem(atPath: source, toPath: payload + "/" + name)
				}
			}
			let guestOld = GuestPaths.share + "/th/old"
			let v5 = try await g.sh(
				"sudo sh \(guestOld)/GuestSetup/install.sh -y --two-way", user: "lab")
			#expect(v5.status == 0, "\(v5.output)")
			let mark = try await g.reportMark()
			try await g.check(
				"cp \(guestOld)/GuestReport/report.env \(GuestPaths.share)/GuestReport/report.env")
			let reported = try await g.waitForReport(newerThan: mark)
			#expect(reported.scriptVersion == 5, "\(reported)")
			let current = try #require(reported.currentScriptVersion)
			#expect(5 < current, "the inspector offers the update (v5, v\(current) available)")
			let again = try await g.reportMark()
			let rerun = try await g.install("-y --two-way", user: "lab", escalation: .sudo)
			#expect(rerun.status == 0, "\(rerun.output)")
			let updated = try await g.waitForReport(newerThan: again)
			#expect(updated.scriptVersion == current, "\(updated)")
		}
	}

	@Test("W1-7: sysvinit Debian keeps rc.local 0755 with both blocks above exit 0")
	func rcLocalReEnabled() async throws {
		var options = THGuestOptions()
		options.mounts = [THAutomount.tag: MountKind.sshfs]
		try await TH.withGuest(.debianSysv, options) { g in
			let marker = try g.marker()
			try await g.check(
				"printf '%s\\n' '#!/bin/sh -e' '# BEGIN \(marker)' '# an older run'"
					+ " '# END \(marker)' 'exit 0' > /etc/rc.local && chmod 644 /etc/rc.local")
			let run = try await g.install(
				"-y --two-way --automount-sshfs", user: "lab", escalation: .sudo)
			#expect(run.status == 0, "\(run.output)")
			try await g.approveReverse()
			let setup = try await g.waitForReport(newerThan: nil)
			let said = ((setup.errors ?? []) + (setup.notes ?? [])).map(\.message)
			let note = "/etc/rc.local was not executable — re-enabled"
				+ " (Machman's boot hook lives there)"
			#expect(said.contains(note), "\(said)")
			let written = g.reportFileDate()
			try await g.reboot()
			#expect(try await g.check("stat -c %a /etc/rc.local") == "755")
			let lines = try await g.check("cat /etc/rc.local").split(separator: "\n")
				.map(String.init)
			let exit = try #require(lines.lastIndex(of: "exit 0"), "\(lines)")
			let blocks = lines.indices.filter { lines[$0].hasPrefix("# BEGIN machman-") }
			#expect(blocks.count >= 2, "both Machman blocks: \(lines)")
			#expect(blocks.allSatisfy { $0 < exit }, "every block sits above exit 0: \(lines)")
			// The boot hook in rc.local ran: the report was written again at boot.
			try await g.waitForReportFile(newerThan: written)
		}
	}
}
