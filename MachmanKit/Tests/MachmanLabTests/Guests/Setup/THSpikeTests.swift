//
//  THSpikeTests.swift
//  MachmanLabTests
//
//  L3 — the installer on OpenBSD 7.9 and NetBSD 11.0 (r3-td's spike images under QEMU; each
//  test cancels with the image's recipe when its image is not built). OpenBSD/arm64's GENERIC
//  has no viocon, so its console rows can only show the skip sentence.
//

import Foundation
import MachmanAPI
import Testing

enum THSpike {
	/// A booted spike guest for `body`; everything stops on every path.
	static func with(
		_ kind: THGuestKind, _ body: (THSpikeGuest) async throws -> Void
	) async throws {
		try await Lab.withAgent { agent in
			let g = try await THSpikeGuest.boot(kind, agent: agent)
			do {
				try await body(g)
				await g.shutdown()
			} catch {
				await g.shutdown()
				throw error
			}
		}
	}

	/// The installer as lab with doas (OpenBSD), or as root for lab (NetBSD: no doas).
	static func install(_ g: THSpikeGuest, _ arguments: String) async throws
		-> (status: Int32, output: String) {
		g.kind == .openbsd
			? try await g.install(arguments, user: "lab", escalation: .doas)
			: try await g.install(arguments + " --user lab")
	}
}

// L3 — OpenBSD and NetBSD spike guests under QEMU.
@Suite("L3 Guest Setup — OpenBSD and NetBSD spikes", .serialized, .enabled(if: Lab.runs(.l3)))
struct THSpikeTests {
	@Test("R3W2-22: OpenBSD without viocon skips consoles with its sentence; ssh sets up")
	func openbsdWithoutViocon() async throws {
		try await THSpike.with(.openbsd) { g in
			let run = try await THSpike.install(g, "-y --console --ssh")
			#expect(run.status == 0, "\(run.output)")
			#expect(TH.unwrapped(run.output).contains(
				"no viocon console driver in this OpenBSD kernel"), "\(run.output)")
			#expect(try await g.sh("rcctl check sshd").status == 0)
			let key = try String(contentsOfFile: g.vm.payloadDir + "/host_key.pub", encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let keys = try await g.check("cat /home/lab/.ssh/authorized_keys")
			#expect(keys.split(separator: "\n").contains { $0 == key }, "\(keys)")
		}
	}

	@Test(
		"W2-2: a second -y --ssh --two-way run edits keys without refusal",
		arguments: [THGuestKind.openbsd, .netbsd])
	func secondRunEditsKeys(kind: THGuestKind) async throws {
		try await THSpike.with(kind) { g in
			for pass in 1...2 {
				let run = try await THSpike.install(g, "-y --ssh --two-way")
				#expect(run.status == 0, "run \(pass):\n\(run.output)")
				#expect(!TH.unwrapped(run.output).contains("changed while it was being edited"),
					"run \(pass):\n\(run.output)")
			}
		}
	}

	@Test("W1-8: OpenBSD keeps ~/.ssh owners and modes and uninstall exits 0")
	func openbsdOwnersAndModes() async throws {
		try await THSpike.with(.openbsd) { g in
			try await g.check(
				"mkdir -p -m 700 /home/lab/.ssh && touch /home/lab/.ssh/config"
					+ " /home/lab/.ssh/authorized_keys && chown lab:lab /home/lab/.ssh/config"
					+ " /home/lab/.ssh/authorized_keys && chmod 640 /home/lab/.ssh/config"
					+ " && chmod 600 /home/lab/.ssh/authorized_keys")
			let config = try await THGuestFiles.stat(g, "/home/lab/.ssh/config")
			let keys = try await THGuestFiles.stat(g, "/home/lab/.ssh/authorized_keys")
			let setUp = try await THSpike.install(g, "-y --two-way")
			#expect(setUp.status == 0, "\(setUp.output)")
			let gone = try await THSpike.install(g, "--uninstall -y")
			#expect(gone.status == 0, "\(gone.output)")
			#expect(try await THGuestFiles.stat(g, "/home/lab/.ssh/config") == config)
			#expect(try await THGuestFiles.stat(g, "/home/lab/.ssh/authorized_keys") == keys)
			let temps = try await g.check("ls -a /home/lab/.ssh | grep '\\.machman-.*~$'; true")
			#expect(temps.isEmpty, "\(temps)")
		}
	}

	@Test("R3W2-21: NetBSD asks for vfs.generic.usermount and keeps it after a reboot")
	func netbsdUsermount() async throws {
		try await THSpike.with(.netbsd) { g in
			// The stock image has no fuse-sshfs and a test boot no network to fetch it: an
			// sshfs stand-in on PATH lets the run reach the user-mount step it gates.
			try await g.check(
				"mkdir -p /usr/local/bin && printf '#!/bin/sh\\necho \"SSHFS version 3.7.3\"\\n'"
					+ " > /usr/local/bin/sshfs && chmod 755 /usr/local/bin/sshfs")
			try await g.check("sysctl -w vfs.generic.usermount=0 >/dev/null")
			let s = g.session()
			try s.start("TERM=dumb \(TH.installer) --sshfs --user lab")
			let run = try await s.drive(proceed: "y", yesNo: "y")
			let asked = run.prompts.contains {
				$0.prompt == .yesNo && TH.unwrapped($0.before).contains("vfs.generic.usermount=1")
			}
			#expect(asked, "the run asked about vfs.generic.usermount:\n\(run.output)")
			// NetBSD raises securelevel to 1 at boot, which refuses raising the knob at run
			// time; /etc/sysctl.conf is applied before that, at the next boot. So the knob is
			// live at once only below securelevel 1; above it, the run must say it takes effect
			// at the next boot.
			let level = Int(try await g.check("sysctl -n kern.securelevel")) ?? 0
			if level < 1 {
				#expect(try await g.check("sysctl -n vfs.generic.usermount") == "1",
					"securelevel \(level):\n\(run.output)")
			} else {
				#expect(TH.unwrapped(run.output).lowercased().contains("next boot"),
					"securelevel \(level), no next-boot note:\n\(run.output)")
			}
			try await g.reboot()
			#expect(try await g.check("sysctl -n vfs.generic.usermount") == "1", "after a reboot")
		}
	}

	@Test("W2-5: NetBSD's plan names ttyVI00, and login, sshd and rc.conf survive a reboot")
	func netbsdConsoleAndSSH() async throws {
		try await THSpike.with(.netbsd) { g in
			let s = g.session()
			try s.start(
				"TERM=dumb \(TH.installer) -n --console --ssh --install --sshfs --user lab")
			let plan = try await s.drive()
			#expect(plan.status == 0, "\(plan.output)")
			#expect(THPlan(plan.output)["consoles"]?.contains("ttyVI00") == true, "\(plan.output)")
			// pkgin when the guest has it; the stock image has pkg_add only.
			let hasPkgin = try await g.sh("command -v pkgin").status == 0
			let parsed = THPlan(plan.output)
			#expect(parsed["guest"]?.hasSuffix(hasPkgin ? "pkgin" : "pkg_add") == true,
				"\(plan.output)")
			#expect(parsed["sshfs"] == "install (fuse-sshfs)", "\(plan.output)")
			let run = try await g.install("-y --console --ssh --user lab")
			#expect(run.status == 0 || run.status == 4, "\(run.output)")
			// The address it tells the Mac to ssh to: NetBSD's ifconfig prints a prefix length.
			let from = try #require(
				run.output.split(separator: "\n").first { $0.hasPrefix("From your Mac:") },
				"no 'From your Mac:' line (exit \(run.status)):\n\(run.output)")
			#expect(!from.contains("/"), "\(from)")
			try await g.reboot()
			let console = try await LabConsole.connect(
				g.consoleSocket(0), transcript: "qemu-\(g.name)-hvc0-after")
			defer { console.close() }
			try await console.login(user: "root", timeout: .seconds(120))
			#expect(try await g.sh("/etc/rc.d/sshd status").output.contains("running"))
			#expect(try await g.sh("grep -q '^sshd=YES' /etc/rc.conf").status == 0)
		}
	}
}
