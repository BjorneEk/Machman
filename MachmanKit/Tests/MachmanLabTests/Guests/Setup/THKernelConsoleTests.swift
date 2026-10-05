//
//  THKernelConsoleTests.swift
//  MachmanLabTests
//
//  L3 — the kernel console flag and the boot-time report: --kernel-console edits GRUB so the
//  kernel talks on hvc0 and the display keeps tty0 (a virtio-gpu device, no window under test
//  mode); after a restart with the installer no longer served, the guest's own report copy
//  turns "next boot" states into what runs, and a guest that never mounts the share stays
//  quiet.
//

import Foundation
import MachmanAPI
import Testing

// L3 — kernel console and boot reports on Debian (GRUB, systemd) under VZ.
@Suite("L3 Guest Setup — kernel console and boot reports", .serialized,
	.enabled(if: Lab.runs(.l3)))
struct THKernelConsoleTests {
	@Test("G16: a --kernel-console run keeps tty0 last and the display bound after reboot")
	func kernelConsoleKeepsTheDisplay() async throws {
		var options = THGuestOptions()
		options.graphics = true
		try await TH.withGuest(.debian, options) { g in
			let run = try await g.install("-y --consoles hvc0 --kernel-console")
			#expect(run.status == 0, "\(run.output)")
			let marker = try g.marker()
			let grub = try await g.check("grep -F \(marker) /etc/default/grub; true")
			#expect(grub.contains("console=hvc0 console=tty0"), "\(grub)")
			#expect(try await g.sh("test -f /boot/grub/grub.cfg.machman-backup").status == 0)
			#expect(try await g.sh("grep -q 'console=hvc0' /boot/grub/grub.cfg").status == 0,
				"update-grub ran")
			let mark = try await g.reportMark()
			try await g.reboot()
			let cmdline = try await g.check("cat /proc/cmdline")
			let consoles = cmdline.split(separator: " ").filter { $0.hasPrefix("console=") }
			#expect(consoles.contains("console=hvc0"), "\(cmdline)")
			#expect(consoles.last == "console=tty0", "the display stays last: \(cmdline)")
			let registered = try await g.check("cat /proc/consoles")
			#expect(registered.contains("hvc0") && registered.contains("tty0"), "\(registered)")
			// The display: a framebuffer console is bound.
			let vt = try await g.check(
				"for v in /sys/class/vtconsole/vtcon*; do echo \"$(cat $v/bind) $(cat $v/name)\";"
					+ " done")
			#expect(vt.split(separator: "\n").contains {
				$0.hasPrefix("1 ") && $0.contains("frame buffer device")
			}, "\(vt)")
			let setup = try await g.waitForReport(newerThan: mark, timeout: .seconds(360))
			let hvc0 = setup.consoles?.first { $0.device == "hvc0" }
			#expect(hvc0?.kernelConsole == true, "\(setup.consoles ?? [])")
		}
	}

	@Test("G17: next-boot console and kernel states turn active after a restart, not served")
	func bootReportRefresh() async throws {
		try await TH.withGuest(.debian) { g in
			let vz = try #require(g as? THVZGuest)
			let mark = try await g.reportMark()
			let run = try await g.install(
				"-y --consoles \"hvc0 hvc1\" --kernel-console --automount-virtiofs")
			#expect(run.status == 0, "\(run.output)")
			let before = try await g.waitForReport(newerThan: mark)
			let pending = before.consoles?.first { $0.device == "hvc0" }
			#expect(pending?.kernelConsolePending == true, "\(before.consoles ?? [])")
			_ = try await g.agent.api.setSetupServed(vm: g.vm.name, serve: false)
			try await g.check("sync")
			try await vz.restartFromHost(remount: false)
			// Not served: the share holds no installer this run.
			let script = g.vm.payloadDir + "/" + GuestSetupInstallerInfo.scriptName
			#expect(!FileManager.default.fileExists(atPath: script), "\(script) is served")
			// W2-8: the boot copy's report lands with no run.
			let after = try await g.waitForReport(
				newerThan: before.lastReportAt, timeout: .seconds(360))
			let hvc0 = after.consoles?.first { $0.device == "hvc0" }
			#expect(hvc0?.kernelConsole == true, "\(after.consoles ?? [])")
			#expect(hvc0?.kernelConsolePending != true, "\(after.consoles ?? [])")
			#expect(!(after.consoles ?? []).contains {
				$0.login == GuestConsoleLogin.configured
			}, "\(after.consoles ?? [])")

			// A guest that never mounts the share stays quiet.
			try await g.check("sed -i '\\| \(GuestPaths.share) |d' /etc/fstab && sync")
			try await vz.restartFromHost(remount: false)
			let quiet = after.lastReportAt
			let deadline = ContinuousClock.now + .seconds(60)
			while ContinuousClock.now < deadline {
				#expect(try await g.vm.info().setup?.lastReportAt == quiet)
				try await Task.sleep(for: .seconds(5))
			}
		}
	}
}
