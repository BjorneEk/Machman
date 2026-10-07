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
	@Test func gettyIsActiveWhateverItsArgumentOrder() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
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

	// S6, S52: the getty-generator's serial-getty@ is active without being enabled — "active
	// (automatic)", which no process line could prove (/dev/null and /dev/zero stand in for
	// the devices). systemd 257 says so in is-enabled's word (enabled-runtime) but exits 0
	// all the same, so the word decides; a guest whose only login is automatic gets the
	// console row off.
	@Test("S52: the getty-generator's login reads active (automatic) though is-enabled exits 0")
	func systemdGeneratorGettyReadsActiveAuto() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				INIT=systemd
				GETTY_MECH=systemd
				ps() { :; }
				systemctl() {
					printf '%s\\n' "$*" >> "$D/systemctl.log"
					case "$1 $2" in
					"is-enabled serial-getty@null.service") echo enabled-runtime ;;
					"is-enabled serial-getty@zero.service") echo enabled ;;
					esac
					return 0
				}
				for dev in null zero; do
					printf '%s %s ' "$dev" "$(console_login_state "$dev")"
					getty_persistent_on "$dev" && echo persistent || echo automatic
				done
				CONSOLE_DEVICES=null
				echo "menu default $(console_menu_default)"
				grep -c 'is-active --quiet serial-getty@null.service' "$D/systemctl.log"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				null active-auto automatic
				zero active persistent
				menu default 0
				2

				""", "\(shell): \(r.out)")
		}
	}

	// S49: the plan's consoles line joined its devices with a hard-coded '·', the one
	// separator that bypassed the ASCII glyphs, and ran past the console on Debian's three
	// consoles; each console now gets a line of its own under the first.
	@Test("S49: the consoles plan lists one console per line, with no '·' between them")
	func consolesPlanListsOneConsolePerLine() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=80
				INIT=systemd
				GETTY_MECH=systemd
				CONSOLE_DEVICES="null zero random"
				ST_CONSOLE_LOGINS="zero"
				ps() { :; }
				systemctl() {
					case "$1 $2" in
					"is-enabled serial-getty@null.service") echo enabled-runtime ;;
					"is-enabled "*) echo enabled ;;
					esac
				}
				CONSOLES_OVERRIDE="null zero random"
				console_decide
				console_plan
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				  consoles         null (automatic - nothing to do)
				                   zero (verify - no changes expected)
				                   random (report only - configured outside Machman)

				""", "\(shell): \(r.out)")
		}
	}

	// S51 (choice C28): a systemd login Machman's runs never enabled is reported and left as
	// is, never adopted: a unit someone else enabled is not ours to take over, as runit's
	// service dirs aren't, so no Leave/Adopt question asks about it. inittab and ttys, where
	// adopting comments a line out, still offer it.
	@Test("S51: a systemd login enabled outside Machman is reported, never adopted")
	func systemdForeignLoginsAreReportedNotAdopted() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				INIT=systemd
				GETTY_MECH=systemd
				CONSOLE_DEVICES="null zero"
				ST_CONSOLE_LOGINS="zero"
				ps() { :; }
				systemctl() { [ "$1" != is-enabled ] || echo enabled; }
				menu_select() { echo "asked: $1"; R_INDEX=2; }
				CONSOLES_OVERRIDE="null zero"
				console_decide
				echo "$CONSOLE_ACTIONS | $CONSOLE_MANAGED"
				console_menu_lines | tr '\\t' '|'
				GETTY_MECH=inittab
				console_foreign_note
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				null=report zero=verify | zero
				null|configured outside Machman — report only
				zero|managed by Machman — verify
				configured outside Machman — adopt or report

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - runit (S18)

	// Void's stock agetty-<dev> runs the shared agetty-generic script through a link: it is
	// enabled by a link of its own, never written; a device Void ships no service for gets
	// a Machman-named one.
	@Test func runitStockServicesAreLinkedNeverWritten() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
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
	@Test func runitDamageIsNamedNeverRewritten() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
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

	// MARK: - Kernel console (S11)

	// The state is gone (or never said grubby): the exact pair Machman sets in grubby's
	// boot entries is named with its remedy and left, and the uninstall ends partial.
	@Test func grubbyArgsWithoutARecordAreNamed() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				OS=Linux
				UI_COLS=200
				CONSOLE_DEVICES="hvc0 hvc1"
				grubby() {
					case "$*" in
					--info=ALL) printf 'index=0\nargs="ro quiet console=hvc1 console=tty0"\n' ;;
					*) echo "grubby $*" >> "$D/grubby.log" ;;
					esac
				}
				kernelconsole_uninstall
				echo "kept=$UNINSTALL_KEPT"
				[ -e "$D/grubby.log" ] || echo "nothing removed"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[!!] console=hvc1 console=tty0 stays in the boot entries - Machman has no record \
				of adding it.
				   Remove it: grubby --update-kernel=ALL --remove-args='console=hvc1 console=tty0'
				kept=1
				nothing removed

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - NetBSD (S13)

	// NetBSD is its own init (rc.d + /etc/ttys), its virtio consoles are viocon's ttyVI<n>0,
	// and its /etc/ttys lines take NetBSD's getty format. Before 10 it has no viocon at all.
	@Test func netbsdInitAndConsoleNames() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				OS=NetBSD
				OS_FAMILY=netbsd
				OS_VERSION=10.1
				detect_init
				console_detect
				echo "$INIT $GETTY_MECH $CONSOLE_DEVICES"
				console_available
				echo "$avail_console"
				OS_VERSION=9.3
				console_available
				echo "$avail_console $reason_console"
				console_act_ttys ttyVI00
				printf '%s\\n' "$CONSOLE_STAGE"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				netbsd-rc ttys ttyVI00 ttyVI10
				1
				0 NetBSD before 10 has no virtio-console driver
				ttyVI00 "/usr/libexec/getty default" vt100 on secure

				""", "\(shell): \(r.out)")
		}
	}

	// pkgsrc names sshfs fuse-sshfs (OpenBSD's ports: sshfs-fuse); pkgin is NetBSD's own.
	@Test func netbsdPackageNames() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				OS_FAMILY=netbsd
				pm_preferred_for_family
				PM=pkgin; pm_command; pkg_for_sshfs; echo "[$(pkg_for_sshd)]"
				PM=pkg_add; pkg_for_sshfs
				OS_FAMILY=openbsd; pkg_for_sshfs
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				pkgin
				pkgin -y install
				fuse-sshfs
				[]
				fuse-sshfs
				sshfs-fuse

				""", "\(shell): \(r.out)")
		}
	}

	// MARK: - OpenBSD (S37)

	// OpenBSD has had viocon(4) since 5.9: its consoles are ttyVI<n>0 like NetBSD's, its
	// logins /etc/ttys lines in NetBSD's format. A kernel without the driver — its boot
	// messages show no viocon — is told apart from one that has it.
	@Test func openbsdInitAndConsoleNames() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				OS=OpenBSD
				OS_FAMILY=openbsd
				OS_VERSION=7.6
				have() { [ "$1" = rcctl ] || command -v "$1" >/dev/null 2>&1; }
				detect_init
				console_detect
				echo "$INIT $GETTY_MECH $CONSOLE_DEVICES"
				dmesg() { printf 'virtio2 at pci0 dev 3 function 0\\nviocon0 at virtio2\\n'; }
				console_available
				echo "$avail_console"
				dmesg() { printf 'virtio2: no matching child driver; not configured\\n'; }
				console_available
				echo "$avail_console $reason_console"
				console_act_ttys ttyVI00
				printf '%s\\n' "$CONSOLE_STAGE"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				openbsd-rc ttys ttyVI00 ttyVI10
				1
				0 no viocon console driver in this OpenBSD kernel
				ttyVI00 "/usr/libexec/getty default" vt100 on secure

				""", "\(shell): \(r.out)")
		}
	}

	// sshd=YES lands once, as the file's last word on sshd (rc.conf is read top to bottom),
	// and a file already saying so is left alone.
	@Test func rcConfEnablesOnce() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				printf 'hostname=nb\nsshd=NO\n#sshd=YES\n' > "$D/rc.conf"
				rc_conf_yes sshd "$D/rc.conf"
				cp "$D/rc.conf" "$D/once"
				rc_conf_yes sshd "$D/rc.conf"
				cmp -s "$D/once" "$D/rc.conf" && echo unchanged
				cat "$D/rc.conf"
				printf 'sshd="yes"  # on\n' > "$D/quoted"
				cp "$D/quoted" "$D/quoted.before"
				rc_conf_yes sshd "$D/quoted"
				cmp -s "$D/quoted.before" "$D/quoted" && echo kept
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				unchanged
				hostname=nb
				sshd=NO
				#sshd=YES
				sshd=YES
				kept

				""", "\(shell): \(r.out)")
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
	@Test func aVerifiedConsoleKeepsItsLineWhenAnotherIsAdded() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.busyboxInittab + """
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
	@Test func unselectedConsolesKeepTheirLines() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.busyboxInittab + """
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

	// S44: a re-run whose lines change format between versions reloaded init even when its
	// session sat on one of the rewritten consoles — the reload ends that login. It says the
	// change waits for the next boot instead; a session on a console whose line stays as it
	// is lets init reload.
	private static let reloadProbe = """
		UI_COLS=1000
		CONSOLE_DEVICES="hvc0 hvc1"
		kill() { echo "kill $*" >> "$D/kill.log"; }
		console_act_inittab hvc0
		console_act_inittab hvc1
		console_flush_and_reload "$D/inittab" | sed "s|$D|D|g"
		echo "kills: $(cat "$D/kill.log" 2>/dev/null)"

		"""

	@Test("S44: a re-run that rewrites its own console's line leaves init alone and says so")
	func aReRunRewritingItsOwnConsoleLeavesInitAlone() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				printf '# BEGIN %s\\nhvc0::respawn:/sbin/getty -L 115200 hvc0 vt100\\n' \\
					"$MARKER" > "$D/inittab"
				printf '# END %s\\n' "$MARKER" >> "$D/inittab"
				console_inittab_is_busybox() { return 0; }
				GETTY_MECH=inittab
				console_session_device() { printf hvc0; }

				""" + Self.reloadProbe, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				   D/inittab changes take effect at the next boot - reloading init now \
				would end this session on hvc0.
				[ok] logins land in D/inittab
				kills: \n
				""", "\(shell): \(r.out)")
		}
	}

	@Test("S44: a re-run that rewrites only other consoles' lines still reloads init")
	func aReRunRewritingOtherConsolesReloadsInit() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(Self.busyboxInittab + """
				console_session_device() { printf hvc0; }

				""" + Self.reloadProbe, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] logins land in D/inittab
				kills: kill -HUP 1\n
				""", "\(shell): \(r.out)")
		}
	}

	// sysvinit ids name the device, never the console's place in this run's selection: a
	// re-run selecting another set never renames a line init runs. An older run's index id
	// for a device being staged again is replaced, not doubled.
	@Test func inittabIdsFollowTheDevice() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
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
	@Test func launchdLabelsFollowTheDevice() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
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
