//
//  THMenuTests.swift
//  MachmanLabTests
//
//  L3 — re-runs and menus: a re-run's menu pre-selects what the state file recorded, a new
//  user and a dropped automount take, and a guest with old artifacts and no state file is
//  re-detected without duplicated lines; an ssh session shows colour and Unicode glyphs while
//  a vt100 console stays ASCII, and the arrow keys move the selection on both.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

enum THMenus {
	/// The menu title of a state-file feature id (feature_title in 90-main.sh).
	static let titles = [
		"console": "Console logins", "ssh": "SSH (Mac -> guest)",
		"reverse": "Guest -> host SSH", "sshfs": "sshfs (mount host folders)",
		"vfsauto": "Automount the share (virtiofs)", "sshfsauto": "Automount sshfs folders",
	]

	/// The files a re-run keeps exactly one marked block in, per kind.
	static func markedFiles(_ kind: THGuestKind, users: [String]) -> [String] {
		var files = users.map { "/home/\($0)/.ssh/config" }
		switch kind {
		case .debian: files.append("/etc/fstab")
		case .alpine: files += ["/etc/fstab", "/etc/inittab"]
		default: files.append("/etc/ttys")
		}
		return files
	}

	/// The pointer lines of every menu draw in `text` (the highlighted item's line).
	static func pointerLines(_ text: String, pointer: String) -> [String] {
		THConsoleSession.clean(text).split(separator: "\n").map(String.init)
			.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(pointer + " ") }
	}
}

// L3 — re-runs, menus and glyphs on Debian, Alpine and FreeBSD.
@Suite("L3 Guest Setup — menus and re-runs", .serialized, .enabled(if: Lab.runs(.l3)))
struct THMenuTests {
	@Test(
		"G10: a re-run pre-selects recorded features and re-detects without state",
		arguments: [THGuestKind.debian, .alpine, .freebsd15])
	func reRuns(kind: THGuestKind) async throws {
		var options = THGuestOptions()
		if kind.isLinux {
			options.mounts = ["projects": MountKind.sshfs, "notes": MountKind.sshfs]
		}
		try await TH.withGuest(kind, options) { g in
			let first = try await g.install(
				"-y --console --two-way"
					+ (kind.isLinux ? " --automount-virtiofs --automount-sshfs" : ""),
				user: "lab", escalation: kind.escalation)
			#expect(first.status == 0, "\(first.output)")
			let configured = try await g.check(
				"sed -n \"s/^CONFIGURED=//p\" \(kind.stateFile) | tr -d \"'\"")
				.split(separator: " ").map(String.init)
			#expect(configured.contains("ssh") && configured.contains("reverse"), "\(configured)")

			// The numbered menu marks every recorded feature.
			let s = g.session()
			try s.start("TERM=dumb \(TH.installer)")
			let menu = try await s.drive(proceed: "q")
			#expect(menu.status == 3, "\(menu.output)")
			let items = THPrompt.menu(menu.before(.toggle) ?? "")
			for id in configured {
				guard let title = THMenus.titles[id] else { continue }
				#expect(items.contains { $0.title.hasPrefix(title) && $0.on },
					"\(id) is recorded but not pre-selected:\n\(menu.output)")
			}

			// Removing an automount: the re-run's folder menu drops "notes".
			if kind.isLinux {
				let beforeRemoval = try await g.reportMark()
				let removal = g.session()
				try removal.start("TERM=dumb \(TH.installer)")
				let run = try await removal.drive(
					toggle: { before in
						guard before.contains("Mount which host folders at boot") else {
							return ""
						}
						return THPrompt.menu(before).first { $0.title.hasPrefix("notes") }
							.map { String($0.number) } ?? ""
					}, proceed: "y")
				#expect(run.status == 0, "\(run.output)")
				let lines = try await THAutomount.sshfsLines(g)
				#expect(lines.contains(GuestPaths.sshfsMountPoint(name: "projects")), "\(lines)")
				#expect(!lines.contains(GuestPaths.sshfsMountPoint(name: "notes")), "\(lines)")
				try await g.waitForReport(newerThan: beforeRemoval)
			}

			// Another user takes SSH over.
			try await g.check(kind.isLinux
				? (kind == .alpine ? "adduser -D -s /bin/sh lab2 && sed -i 's/^lab2:!:/lab2:*:/'"
					+ " /etc/shadow" : "useradd -m -s /bin/sh lab2")
				: "pw useradd lab2 -m -s /bin/sh")
			let moved = try await g.install("-y --user lab2")
			#expect(moved.status == 0, "\(moved.output)")
			try await g.waitForInfo("SSH reported for lab2") { $0.ssh?.guestUser == "lab2" }

			// No state file (a v2-configured guest): everything is found again, once.
			try await g.check("rm -f \(kind.stateFile)")
			let again = try await g.install("-y")
			#expect(again.status == 0, "\(again.output)")
			let marker = try g.marker()
			for file in THMenus.markedFiles(kind, users: ["lab", "lab2"]) {
				let blocks = try await THGuestFiles.markerBlocks(g, file, marker: marker)
				#expect(blocks <= 1, "\(file) holds \(blocks) blocks")
			}
			for user in ["lab", "lab2"] {
				let keys = try await g.check(
					"grep -c -F \(marker) /home/\(user)/.ssh/authorized_keys; true")
				#expect((Int(keys) ?? 0) <= 1, "\(user)'s authorized_keys: \(keys) Machman keys")
			}
		}
	}

	@Test(
		"G11: an ssh session run shows colour and unicode; vt100 stays ASCII",
		arguments: [THGuestKind.debian, .alpine, .freebsd15])
	func glyphsByTerminal(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			// root reaches lab over the guest's own sshd (a real pty, TERM from the client).
			let rootKey = kind.isLinux ? "/root/.ssh/id_ed25519" : "/root/.ssh/id_ed25519"
			try await g.check(
				"mkdir -p -m 700 /root/.ssh && { test -f \(rootKey) || ssh-keygen -q -t ed25519"
					+ " -N '' -f \(rootKey) </dev/null; } && mkdir -p -m 700 /home/lab/.ssh"
					+ " && cat \(rootKey).pub >> /home/lab/.ssh/authorized_keys"
					+ " && chown -R lab /home/lab/.ssh && chmod 600 /home/lab/.ssh/authorized_keys")
			let line = kind.escalation.apply(GuestCommand(TH.installer))
			let ssh = g.session()
			try ssh.start(
				"TERM=xterm-256color LANG=C.UTF-8 ssh -tt -o StrictHostKeyChecking=accept-new"
					+ " -o UserKnownHostsFile=/tmp/th_known lab@localhost"
					+ " \(ShellQuote.single(line))")
			let remote = try await ssh.drive(multiKeys: [THKey.down, THKey.q])
			#expect(remote.status == 3, "\(remote.output)")
			let text = String(decoding: try await ssh.raw(), as: UTF8.self)
			#expect(!THGlyphs.colours(in: text).isEmpty, "an ssh session shows colour")
			#expect(THGlyphs.unicode.contains { text.contains($0) }, "and Unicode glyphs")
			let moved = THMenus.pointerLines(text, pointer: "❯")
			#expect(moved.count >= 2 && moved.first != moved.last,
				"Down moves the selection: \(moved)")

			let vt = g.session()
			try vt.start("TERM=vt100 LANG=C LC_ALL=C \(TH.installer)")
			let local = try await vt.drive(multiKeys: [THKey.down, THKey.q])
			#expect(local.status == 3, "\(local.output)")
			let ascii = String(decoding: try await vt.raw(), as: UTF8.self)
			let steps = THMenus.pointerLines(ascii, pointer: ">")
			#expect(steps.count >= 2 && steps.first != steps.last,
				"Down moves the selection on vt100: \(steps)")
			for glyph in THGlyphs.unicode {
				#expect(!ascii.contains(glyph), "'\(glyph)' on a vt100 console")
			}
		}
	}
}
