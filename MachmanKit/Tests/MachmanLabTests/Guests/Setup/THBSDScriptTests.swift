//
//  THBSDScriptTests.swift
//  MachmanLabTests
//
//  L3 — the installer on FreeBSD under QEMU (beside its carrier VM): key and config edits on a
//  second run, owners and modes kept through an uninstall, the /dev/fd question for the key
//  step, and the user-mount sysctl kept across a reboot (and no "ready" claim without fuse).
//

import Foundation
import MachmanAPI
import Testing

// L3 — FreeBSD script rows (QEMU) and the rename automount.
@Suite("L3 Guest Setup — FreeBSD runs", .serialized, .enabled(if: Lab.runs(.l3)))
struct THBSDScriptTests {
	@Test("W2-2: a second -y --ssh --two-way run on FreeBSD 14 edits keys without refusal")
	func secondRunEditsKeys() async throws {
		try await TH.withGuest(.freebsd14) { g in
			for pass in 1...2 {
				let run = try await g.install("-y --ssh --two-way", user: "lab", escalation: .doas)
				#expect(run.status == 0, "run \(pass):\n\(run.output)")
				#expect(!TH.unwrapped(run.output).contains("changed while it was being edited"),
					"run \(pass):\n\(run.output)")
			}
			let marker = try g.marker()
			for file in ["/home/lab/.ssh/config"] {
				#expect(try await THGuestFiles.markerBlocks(g, file, marker: marker) == 1)
			}
			let keys = try await g.check(
				"grep -c -F \(marker) /home/lab/.ssh/authorized_keys; true")
			#expect(keys == "1", "\(keys)")
		}
	}

	@Test("W1-8: FreeBSD keeps ~/.ssh owners and modes and no temp files after uninstall")
	func ownersAndModesKept() async throws {
		try await TH.withGuest(.freebsd15) { g in
			try await g.check(
				"mkdir -p -m 700 /home/lab/.ssh && touch /home/lab/.ssh/config"
					+ " /home/lab/.ssh/authorized_keys && chown lab:lab /home/lab/.ssh/config"
					+ " /home/lab/.ssh/authorized_keys && chmod 640 /home/lab/.ssh/config"
					+ " && chmod 600 /home/lab/.ssh/authorized_keys")
			let config = try await THGuestFiles.stat(g, "/home/lab/.ssh/config")
			let keys = try await THGuestFiles.stat(g, "/home/lab/.ssh/authorized_keys")
			let setUp = try await g.install("-y --two-way", user: "lab", escalation: .doas)
			#expect(setUp.status == 0, "\(setUp.output)")
			let gone = try await g.install("--uninstall -y", user: "lab", escalation: .doas)
			#expect(gone.status == 0, "\(gone.output)")
			#expect(try await THGuestFiles.stat(g, "/home/lab/.ssh/config") == config)
			#expect(try await THGuestFiles.stat(g, "/home/lab/.ssh/authorized_keys") == keys)
			let temps = try await g.check("ls -a /home/lab/.ssh | grep '^\\..*\\.machman-.*~$'; true")
			#expect(temps.isEmpty, "\(temps)")
		}
	}

	@Test("W1-25: with fdescfs on /dev/fd the FreeBSD ssh-key step succeeds")
	func fdescfsKeyStep() async throws {
		try await TH.withGuest(.freebsd15) { g in
			try await g.check("mount | grep -q ' on /dev/fd ' || mount -t fdescfs fdesc /dev/fd")
			let run = try await g.install("-y --ssh", user: "lab", escalation: .doas)
			#expect(run.status == 0, "\(run.output)")
			#expect(!TH.unwrapped(run.output).contains("changed while it was being edited"),
				"\(run.output)")
		}
	}

	@Test("R3W2-21: --mount-setup keeps vfs.usermount, and no fusefs gives no ready line")
	func usermountKept() async throws {
		try await TH.withGuest(.freebsd15) { guest in
			let g = try #require(guest as? THBSDGuest)
			let run = try await g.install(
				"-y --sshfs --mount-setup", user: "lab", escalation: .doas)
			#expect(run.status == 0, "\(run.output)")
			let block = try await g.check("grep -n 'machman' /etc/sysctl.conf; true")
			#expect(block.contains("usermount"), "\(block)")
			try await g.reboot(remount: false)
			#expect(try await g.check("sysctl -n vfs.usermount") == "1")
			// The payload, copied local; then no fuse at all in this guest.
			try await g.mountShare()
			try await g.check(
				"rm -rf /tmp/thsh && mkdir -p /tmp/thsh && cp -R \(GuestPaths.share)/GuestSetup"
					+ " \(GuestPaths.share)/GuestReport /tmp/thsh/ && umount \(GuestPaths.share)")
			try await g.check(
				"kldunload fusefs && mv /boot/kernel/fusefs.ko /boot/kernel/fusefs.ko.th")
			let again = try await g.sh(
				"sh /tmp/thsh/GuestSetup/install.sh -y --sshfs --mount-setup")
			#expect(!TH.unwrapped(again.output).contains("ready for host folders"),
				"\(again.output)")
		}
	}
}
