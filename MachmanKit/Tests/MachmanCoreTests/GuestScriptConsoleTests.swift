//
//  GuestScriptConsoleTests.swift
//  MachmanTests
//
//  The console-login feature's detection and edits (20-detect, 40-console), run for real
//  under every local POSIX shell through GuestScriptHarness. System files and the process
//  table are stand-ins under the probe's scratch dir; scripts/guest-regress checks the same
//  over real inittab, runit and ttys layouts as root.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptConsoleTests {

	// S6: a login is live wherever its device shows on the getty's process line — systemd's
	// serial-getty@ (the device only in the TTY column), our agetty lines, busybox getty,
	// FreeBSD's 3wire getty — and never on a longer name that merely starts the same.
	@Test func gettyIsActiveWhateverItsArgumentOrder() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				ps() { printf '  PID TTY      STAT   TIME COMMAND\n%s\n' "$PS_LINE"; }
				probe() {
					PS_LINE="$2"
					if getty_active_on "$1"; then echo "$1 active"; else echo "$1 idle"; fi
				}
				probe hvc0 '  812 hvc0     Ss+    0:00 /sbin/agetty -o -- \u --noreset - vt220'
				probe hvc0 '   90 ?        Ss     0:00 /usr/sbin/agetty -L hvc0 115200 vt100'
				probe hvc0 '    1 root     /sbin/getty 38400 hvc0'
				probe hvc1 '   44 ?        Ss     0:00 agetty hvc1 115200 vt100'
				probe ttyV0.0 '  812 v0.0  Is+   0:00.01 /usr/libexec/getty 3wire ttyV0.0'
				probe hvc0 '  700 tty1     Ss+    0:00 /sbin/agetty -o -- \u --noclear - linux'
				probe hvc1 '   91 ?        Ss     0:00 /usr/sbin/agetty -L hvc10 115200 vt100'
				probe hvc1 '   92 pts/0    S      0:00 vi hvc1.log'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				hvc0 active
				hvc0 active
				hvc0 active
				hvc1 active
				ttyV0.0 active
				hvc0 idle
				hvc1 idle
				hvc1 idle

				""", "\(shell): \(r.out)")
		}
	}

	// S6: the getty-generator's serial-getty@ is active without being enabled — "active
	// (automatic)", which no process line could prove (/dev/null stands in for the device).
	@Test func systemdGeneratorGettyReadsActiveAuto() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run("""
				INIT=systemd
				GETTY_MECH=systemd
				ps() { :; }
				systemctl() {
					printf '%s\\n' "$*" >> "$D/systemctl.log"
					case "$1" in is-active) return 0 ;; *) return 1 ;; esac
				}
				console_login_state null
				grep -c 'is-active --quiet serial-getty@null.service' "$D/systemctl.log"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "active-auto\n1\n", "\(shell): \(r.out)")
		}
	}
}
