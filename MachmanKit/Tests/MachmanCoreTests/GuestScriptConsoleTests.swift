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

	// MARK: - runit (S18)

	// Void's stock agetty-<dev> runs the shared agetty-generic script through a link: it is
	// enabled by a link of its own, never written; a device Void ships no service for gets
	// a Machman-named one.
	@Test func runitStockServicesAreLinkedNeverWritten() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				RUNIT_SV_DIR="$D/sv"
				RUNIT_SERVICE_DIR="$D/service"
				mkdir -p "$RUNIT_SV_DIR/agetty-generic" "$RUNIT_SV_DIR/agetty-hvc0" \
					"$RUNIT_SERVICE_DIR"
				printf '#!/bin/sh\ntty=${PWD##*-}\n' > "$RUNIT_SV_DIR/agetty-generic/run"
				ln -s ../agetty-generic/run "$RUNIT_SV_DIR/agetty-hvc0/run"
				agetty() { :; }
				console_act_runit hvc0
				console_act_runit hvc1
				console_act_runit hvc1
				cat "$RUNIT_SV_DIR/agetty-generic/run"
				readlink "$RUNIT_SV_DIR/agetty-hvc0/run"
				readlink "$RUNIT_SERVICE_DIR/agetty-hvc0" | sed "s|$D|D|"
				readlink "$RUNIT_SERVICE_DIR/machman-agetty-hvc1" | sed "s|$D|D|"
				ls -ln "$RUNIT_SV_DIR/machman-agetty-hvc1/run" | cut -c1-10
				cat "$RUNIT_SV_DIR/machman-agetty-hvc1/run"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				#!/bin/sh
				tty=${PWD##*-}
				../agetty-generic/run
				D/sv/agetty-hvc0
				D/sv/machman-agetty-hvc1
				-rwxr-xr-x
				#!/bin/sh
				# \(GuestScriptHarness.marker)
				exec agetty -L hvc1 115200 vt100

				"""), "\(shell): \(r.out)")
		}
	}

	// An older Machman's write through such a link (here a cloned disk's source VM's) left
	// the shared script carrying a marker: the run names Void's own repair and never
	// rewrites the script; the uninstall leaves it too and ends partial.
	@Test func runitDamageIsNamedNeverRewritten() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				RUNIT_SV_DIR="$D/sv"
				RUNIT_SERVICE_DIR="$D/service"
				mkdir -p "$RUNIT_SV_DIR/agetty-generic" "$RUNIT_SERVICE_DIR"
				printf '#!/bin/sh\n# machman-0ddc105e9999\nexec agetty hvc0 115200 vt100\n' \
					> "$RUNIT_SV_DIR/agetty-generic/run"
				cp "$RUNIT_SV_DIR/agetty-generic/run" "$D/generic.before"
				GETTY_MECH=runit
				CONSOLE_SELECTED=""
				console_runit_damaged && echo damaged
				console_act
				console_uninstall
				printf '%s|%s\n' "$FAILED_STEPS" "$UNINSTALL_KEPT"
				printf '%s\n' "$ERR_LINES" | sed "s|$D|D|"
				cmp -s "$D/generic.before" "$RUNIT_SV_DIR/agetty-generic/run" && echo kept
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasPrefix("damaged\n"), "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				console|1
				console: an older Machman overwrote Void's shared getty script \
				(D/sv/agetty-generic/run) — restore it with 'xbps-install -f runit-void'
				kept

				"""), "\(shell): \(r.out)")
		}
	}

	// MARK: - inittab / ttys blocks (S21)

	// A guest inittab with one Machman-managed login (busybox format) beside its own.
	private static let busyboxInittab = """
		printf 'tty1::respawn:/sbin/getty 38400 tty1\\n# BEGIN %s\\n' "$MARKER" > "$D/inittab"
		printf 'hvc0::respawn:/sbin/getty 38400 hvc0\\n# END %s\\n' "$MARKER" >> "$D/inittab"
		console_inittab_is_busybox() { return 0; }
		GETTY_MECH=inittab

		"""

	// A re-run that verifies hvc0 and adds hvc1 stages both: the block holds each once,
	// and a run that changes nothing leaves the file alone (no rewrite, no init reload).
	@Test func aVerifiedConsoleKeepsItsLineWhenAnotherIsAdded() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.busyboxInittab + """
				console_act_inittab hvc0
				console_act_inittab hvc1
				console_flush_lines "$D/inittab" && echo flushed
				cat "$D/inittab"
				console_act_inittab hvc0
				console_act_inittab hvc1
				console_flush_lines "$D/inittab" || echo unchanged
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				flushed
				tty1::respawn:/sbin/getty 38400 tty1
				# BEGIN \(GuestScriptHarness.marker)
				hvc0::respawn:/sbin/getty 38400 hvc0
				hvc1::respawn:/sbin/getty 38400 hvc1
				# END \(GuestScriptHarness.marker)
				unchanged

				""", "\(shell): \(r.out)")
		}
	}

	// A console the run does not touch keeps its line: the flush replaces only the lines of
	// the devices it staged.
	@Test func unselectedConsolesKeepTheirLines() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.busyboxInittab + """
				console_act_inittab hvc1
				console_flush_lines "$D/inittab"
				cat "$D/inittab"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				tty1::respawn:/sbin/getty 38400 tty1
				# BEGIN \(GuestScriptHarness.marker)
				hvc0::respawn:/sbin/getty 38400 hvc0
				hvc1::respawn:/sbin/getty 38400 hvc1
				# END \(GuestScriptHarness.marker)

				""", "\(shell): \(r.out)")
		}
	}

	// sysvinit ids name the device, never the console's place in this run's selection: a
	// re-run selecting another set never renames a line init runs. An older run's index id
	// for a device being staged again is replaced, not doubled.
	@Test func inittabIdsFollowTheDevice() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run("""
				printf '# BEGIN %s\\nM0:2345:respawn:/sbin/agetty -L hvc1 115200 vt100\\n' \\
					"$MARKER" > "$D/inittab"
				printf '# END %s\\n' "$MARKER" >> "$D/inittab"
				console_inittab_is_busybox() { return 1; }
				agetty() { :; }
				GETTY_MECH=inittab
				console_act_inittab hvc1
				console_act_inittab ttyAMA0
				console_flush_lines "$D/inittab"
				cat "$D/inittab"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				# BEGIN \(GuestScriptHarness.marker)
				hv1:2345:respawn:agetty -L hvc1 115200 vt100
				MMA0:2345:respawn:agetty -L ttyAMA0 115200 vt100
				# END \(GuestScriptHarness.marker)

				""", "\(shell): \(r.out)")
		}
	}

	// macOS: one plist per DEVICE. An older run's index-keyed plist for the device is booted
	// out and removed; another device's is left alone. (/dev/zero and /dev/null stand in
	// for the guest's cu.virtio ports, which a Mac has no /dev entry for.)
	@Test func launchdLabelsFollowTheDevice() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				LAUNCHD_DIR="$D/LaunchDaemons"
				mkdir -p "$LAUNCHD_DIR"
				launchctl() { printf '%s\n' "$*" >> "$D/launchctl.log"; }
				chown() { :; }
				old() {
					printf '<plist><array><string>/usr/libexec/getty</string>' \
						> "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX.$1.plist"
					printf '<string>%s</string></array></plist>\n' "$2" \
						>> "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX.$1.plist"
				}
				old 0 zero
				old 1 null
				console_act_launchd zero
				ls "$LAUNCHD_DIR"
				grep -c "<string>$LAUNCHD_GETTY_PREFIX.zero</string>" \
					"$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX.zero.plist"
				ls -ln "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX.zero.plist" | cut -c1-10
				sed "s|$D|D|" "$D/launchctl.log"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				com.machman.console-getty.1.plist
				com.machman.console-getty.zero.plist
				1
				-rw-r--r--
				bootout system/com.machman.console-getty.0
				bootout system/com.machman.console-getty.zero
				bootstrap system D/LaunchDaemons/com.machman.console-getty.zero.plist

				"""), "\(shell): \(r.out)")
		}
	}
}
