//
//  THConsoleLoginTests.swift
//  MachmanLabTests
//
//  L3 — console logins the installer sets up, checked on the consoles themselves: a login
//  prompt answers and root logs in, the init mechanism holds the guest's own record (systemd
//  units, /etc/inittab and /etc/ttys marker blocks), the report says what each console reads.
//

import Foundation
import MachmanAPI
import Testing

enum THConsoles {
	/// The lines between `marker`'s BEGIN and END lines in `file`.
	static func block(_ g: any THGuest, _ file: String, marker: String) async throws
		-> [String] {
		let out = try await g.check(
			"awk -v m=\(ShellQuote.single(marker)) '$0 == \"# BEGIN \" m { inb = 1; next }"
				+ " $0 == \"# END \" m { inb = 0; next } inb' \(file)")
		return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
	}

	/// Root logs in on `console` (a getty answers there) and the shell is on `tty`.
	static func expectLogin(_ console: LabConsole, tty: String) async throws {
		try await console.login(user: "root", timeout: .seconds(60))
		let seen = try await THConsoleSession.run(console, "tty")
		#expect(seen.output.hasSuffix(tty), "\(seen.output)")
	}

	/// No login prompt on `console` for `seconds`.
	static func expectNoLogin(_ console: LabConsole, seconds: Int = 30) async {
		try? console.send("")
		do {
			try await console.expect("login: *$", timeout: .seconds(seconds))
			Issue.record("a login prompt answered on \(console.path)")
		} catch {}
	}
}

// L3 — console logins on Debian (systemd), Alpine (inittab) and FreeBSD (QEMU, /etc/ttys).
@Suite("L3 Guest Setup — console logins", .serialized, .enabled(if: Lab.runs(.l3)))
struct THConsoleLoginTests {
	@Test("W2-1: hvc0 reads active (automatic) after setup on systemd Debian")
	func hvc0ReadsAutomatic() async throws {
		try await TH.withGuest(.debian) { g in
			// The row's guest: hvc0's login is systemd's own (getty-generator), not enabled.
			let unit = "serial-getty@hvc0.service"
			let before = try await g.sh(
				"systemctl is-enabled \(unit); systemctl is-active \(unit);"
					+ " ls /etc/systemd/system/getty.target.wants/ 2>/dev/null").output
			try await g.check("systemctl disable \(unit) >/dev/null 2>&1; true")
			let started = try await g.reportMark()
			let run = try await g.install("-y --console --ssh")
			#expect(run.status == 0, "\(run.output)")
			let setup = try await g.waitForReport(newerThan: started)
			let hvc0 = setup.consoles?.first { $0.device == "hvc0" }
			let now = try await g.sh("systemctl is-enabled \(unit)").output
			#expect(hvc0?.login != nil, "\(setup.consoles ?? [])")
			// systemd 257 says enabled-runtime for the generator's unit, and exits 0.
			#expect(hvc0?.login == GuestConsoleLogin.activeAuto,
				"\(setup.consoles ?? []); before: \(before); is-enabled now: \(now)")
		}
	}

	@Test("G5: a second console gets serial-getty@hvc1 and answers a login")
	func secondConsoleGetsAGetty() async throws {
		try await TH.withGuest(.debian) { g in
			let run = try await g.install("-y --consoles \"hvc0 hvc1\"")
			#expect(run.status == 0, "\(run.output)")
			let unit = "serial-getty@hvc1.service"
			#expect(try await g.sh("systemctl is-enabled \(unit)").output == "enabled")
			#expect(try await g.sh("systemctl is-active \(unit)").output == "active")
			let hvc1 = try await g.vm.console(1, label: "hvc1")
			defer { hvc1.close() }
			try await THConsoles.expectLogin(hvc1, tty: "/dev/hvc1")
		}
	}

	@Test("G6: Alpine's getty lines sit between the markers and HUP brings the login up")
	func alpineInittabLines() async throws {
		try await TH.withGuest(.alpine) { g in
			// -v narrates the init reload (run quietly otherwise).
			let run = try await g.install("-y -v --consoles \"hvc0 hvc1\"")
			#expect(run.status == 0, "\(run.output)")
			#expect(run.output.contains("kill -HUP 1"), "\(run.output)")
			#expect(run.output.contains("logins land in /etc/inittab"), "\(run.output)")
			let block = try await THConsoles.block(g, "/etc/inittab", marker: try g.marker())
			for dev in ["hvc0", "hvc1"] {
				#expect(block.contains { $0.hasPrefix("\(dev)::respawn:") && $0.contains(dev) },
					"\(block)")
			}
			#expect(block.count == 2, "\(block)")
			// No reboot: init re-read the table, so the login is up now.
			let hvc1 = try await g.vm.console(1, label: "hvc1")
			defer { hvc1.close() }
			try await THConsoles.expectLogin(hvc1, tty: "/dev/hvc1")
		}
	}

	@Test("G7: FreeBSD loads virtio_console, adds the ttyV0.0 line and HUP shows the login")
	func freebsdTtysLine() async throws {
		try await TH.withGuest(.freebsd15) { g in
			let qemu = try #require((g as? THBSDGuest)?.qemu)
			let run = try await g.install("-y --console")
			#expect(run.status == 0, "\(run.output)")
			#expect(try await g.sh("kldstat -v | grep -q virtio_console").status == 0)
			let persisted = try await g.sh(
				"sysrc -n kld_list | grep -qw virtio_console"
					+ " || grep -q '^virtio_console_load=\"YES\"' /boot/loader.conf")
			#expect(persisted.status == 0, "virtio_console stays loaded across reboots")
			let block = try await THConsoles.block(g, "/etc/ttys", marker: try g.marker())
			#expect(block == ["ttyV0.0 \"/usr/libexec/getty 3wire\" vt100 onifexists secure"],
				"\(block)")
			let console = try await qemu.console(0)
			defer { console.close() }
			try await THConsoles.expectLogin(console, tty: "/dev/ttyV0.0")
		}
	}

	@Test(
		"G7: a ttyV login comes up under VZ on the vzfreebsd image",
		.enabled(if: VZFreeBSD.imageExists, Comment(rawValue: VZFreeBSD.skipReason)))
	func vzfreebsdTtysLine() async throws {
		try await THVZFreeBSD.withGuest { g, payload in
			let ports = try await g.check("ls /dev/ttyV* | sed 's|/dev/||'")
				.split(separator: "\n").map(String.init)
			let second = try #require(ports.count >= 2 ? ports[1] : nil, "\(ports)")
			// The image has no user but root (as the BSD guide's guests): name it.
			let run = try await g.sh(
				"sh \(payload)/GuestSetup/install.sh -y --user root --consoles \(second)")
			#expect(run.status == 0, "\(run.output)")
			let console = try await g.vm.console(1, label: "ttyV")
			defer { console.close() }
			try await THConsoles.expectLogin(console, tty: "/dev/\(second)")
		}
	}

	@Test("W2-3: a re-run selecting only the second console keeps both ttyV lines")
	func reRunKeepsBothLines() async throws {
		var options = THGuestOptions()
		options.bsdConsoles = 2
		try await TH.withGuest(.freebsd15, options) { g in
			let qemu = try #require((g as? THBSDGuest)?.qemu)
			let first = try await g.install("-y --consoles \"ttyV0.0 ttyV0.1\"")
			#expect(first.status == 0, "\(first.output)")
			let again = try await g.install("-y --consoles ttyV0.1")
			#expect(again.status == 0, "\(again.output)")
			let block = try await THConsoles.block(g, "/etc/ttys", marker: try g.marker())
			for dev in ["ttyV0.0", "ttyV0.1"] {
				#expect(block.contains { $0.hasPrefix(dev + " ") }, "\(block)")
			}
			for (index, dev) in ["ttyV0.0", "ttyV0.1"].enumerated() {
				let console = try await qemu.console(index)
				defer { console.close() }
				try await THConsoles.expectLogin(console, tty: "/dev/\(dev)")
			}
		}
	}

	// S44: a re-run whose getty line changes form (an older Machman named sysvinit ids by
	// the console's index) reloaded init under the session sitting on that console, and
	// sysvinit ends a changed entry's processes. The run says the reload waits instead.
	@Test(
		"S44: a re-run from a console whose line changes form keeps that session",
		arguments: [THGuestKind.debianSysv])
	func reRunFromARewrittenConsole(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			let setUp = try await g.install("-y --consoles \"hvc0 hvc1\"")
			#expect(setUp.status == 0, "\(setUp.output)")
			// hvc1's line as an older Machman wrote it, and init running it so.
			_ = try await g.check("sed -i 's/^hv1:/M1:/' /etc/inittab && kill -HUP 1")
			let block = try await THConsoles.block(g, "/etc/inittab", marker: try g.marker())
			try #require(block.contains { $0.hasPrefix("M1:") }, "\(block)")
			let hvc1 = try await g.vm.console(1, label: "hvc1")
			defer { hvc1.close() }
			try await hvc1.login(user: "root", timeout: .seconds(60))
			let s = THConsoleSession(hvc1)
			try s.start("\(TH.installer) -y --consoles \"hvc0 hvc1\"")
			let run = try await s.finish(timeout: .seconds(300))
			#expect(run.status == 0, "\(run.output)")
			#expect(TH.ascii(TH.unwrapped(run.output)).contains(TH.ascii("/etc/inittab changes"
				+ " take effect at the next boot — reloading init now would end this session on"
				+ " hvc1.")), "\(run.output)")
			let alive = try await THConsoleSession.run(hvc1, "echo th-alive")
			#expect(alive.output == "th-alive", "the session on hvc1 still answers")
			let now = try await THConsoles.block(g, "/etc/inittab", marker: try g.marker())
			#expect(now.contains { $0.hasPrefix("hv1:") } && !now.contains { $0.hasPrefix("M1:") },
				"\(now)")
		}
	}

	@Test(
		"R3W2-19: uninstall from a hvc1 login keeps the session until the next boot",
		arguments: [THGuestKind.debian, .alpine])
	func uninstallFromHvc1(kind: THGuestKind) async throws {
		try await TH.withGuest(kind) { g in
			let setUp = try await g.install("-y --consoles \"hvc0 hvc1\"")
			#expect(setUp.status == 0, "\(setUp.output)")
			let vz = try #require(g as? THVZGuest)
			let hvc1 = try await g.vm.console(1, label: "hvc1")
			try await hvc1.login(user: "root", timeout: .seconds(60))
			let s = THConsoleSession(hvc1)
			try s.start("\(TH.installer) --uninstall -y")
			let run = try await s.finish(timeout: .seconds(300))
			#expect(run.status == 0 || run.status == 4, "\(run.output)")
			// As an ASCII terminal shows it: the login's locale decides (TH.ascii).
			let said = TH.ascii(TH.unwrapped(run.output))
			if kind == .alpine {
				#expect(said.contains(TH.ascii("/etc/inittab changes take effect at the next boot"
					+ " — reloading init now would end this session on hvc1.")), "\(run.output)")
			} else {
				#expect(said.contains(TH.ascii("hvc1 keeps its login until the next boot —"
					+ " stopping it now would end this session.")), "\(run.output)")
			}
			let alive = try await THConsoleSession.run(hvc1, "echo th-alive")
			#expect(alive.output == "th-alive", "the session on hvc1 still answers")
			if kind == .debian {
				// hvc2's login is the image's own (the lab's driver), never Machman's: the
				// uninstall must leave it enabled and running, and say so.
				#expect(said.contains("hvc2 keeps its login (set up outside Machman)."),
					"\(run.output)")
				let unit = "serial-getty@hvc2.service"
				let state = try await THConsoleSession.run(
					hvc1, "systemctl is-enabled \(unit); systemctl is-active \(unit)")
				#expect(state.output == "enabled\nactive", "\(state.output)")
			}
			// The connection stays through the reboot: only what the new boot prints counts
			// (a fresh connection would replay the old session's output).
			_ = try await THConsoleSession.run(hvc1, "echo th-before-reboot")
			try await vz.reboot()
			if (try? hvc1.send("")) != nil {
				await THConsoles.expectNoLogin(hvc1)
				hvc1.close()
			} else {
				hvc1.close()
				let fresh = try await g.vm.console(1, label: "hvc1-after")
				defer { fresh.close() }
				await THConsoles.expectNoLogin(fresh)
			}
			if kind == .alpine {
				#expect(try await g.sh("grep -q hvc1 /etc/inittab").status != 0)
			} else {
				let enabled = try await g.sh("systemctl is-enabled serial-getty@hvc1.service")
				#expect(enabled.output != "enabled", "\(enabled.output)")
			}
		}
	}
}
