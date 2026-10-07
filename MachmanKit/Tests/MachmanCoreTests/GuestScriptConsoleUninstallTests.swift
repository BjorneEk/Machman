//
//  GuestScriptConsoleUninstallTests.swift
//  MachmanTests
//
//  S41: --uninstall run from a console login Machman set up (the obvious place on a headless
//  guest) keeps that login until the next boot instead of ending its own session halfway.
//  40-console's uninstall per getty mechanism, run under every local POSIX shell through
//  GuestScriptHarness; init, systemctl, launchctl and the session's terminal are stand-ins.
//  UI_COLS=1000: the script folds what it says at the terminal's width; these read it whole.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptConsoleUninstallTests {

	// systemd: the session's own console is disabled for the next boot but not stopped; the
	// others stop now, as before.
	@Test func systemdDisablesTheSessionsConsoleWithoutStoppingIt() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				GETTY_MECH=systemd
				CONSOLE_DEVICES="hvc0 hvc1"
				ST_CONSOLE_LOGINS="hvc0 hvc1"
				systemctl() {
					printf '%s\\n' "$*" >> "$D/systemctl.log"
					[ "$1" != is-enabled ] || echo enabled
				}
				console_session_device() { printf hvc1; }
				console_uninstall
				console_session_device() { :; }
				console_uninstall
				echo ---
				grep -v is-enabled "$D/systemctl.log"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				   hvc1 keeps its login until the next boot - stopping it now would end \
				this session.
				---
				disable --now serial-getty@hvc0.service
				disable serial-getty@hvc1.service
				disable --now serial-getty@hvc0.service
				disable --now serial-getty@hvc1.service

				""", "\(shell): \(r.out)")
		}
	}

	// S51: a systemd unit names no owner, so a login is Machman's only when a run of the
	// script enabled it (the state lists it), and the uninstall disables only those, while
	// is-enabled still says "enabled": hvc0's getty-generator unit (enabled-runtime) is
	// systemd's own, and a login the image or the admin enabled stays — said so.
	@Test("S51: uninstall disables only the logins the state lists, and only while enabled")
	func systemdUninstallKeepsLoginsMachmanNeverEnabled() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				INIT=systemd
				GETTY_MECH=systemd
				CONSOLE_DEVICES="hvc0 hvc1 hvc2"
				ST_CONSOLE_LOGINS="hvc1"
				systemctl() {
					printf '%s\\n' "$*" >> "$D/systemctl.log"
					case "$1 $2" in
					"is-enabled serial-getty@hvc0.service") echo enabled-runtime ;;
					"is-enabled "*) echo enabled ;;
					esac
				}
				console_session_device() { :; }
				console_uninstall
				echo ---
				grep -v is-enabled "$D/systemctl.log"
				echo ---
				for dev in hvc0 hvc1 hvc2; do echo "$dev $(console_ownership "$dev")"; done
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				   hvc2 keeps its login (set up outside Machman).
				---
				disable --now serial-getty@hvc1.service
				---
				hvc0 none
				hvc1 ours
				hvc2 foreign

				""", "\(shell): \(r.out)")
		}
	}

	// inittab and ttys: the lines go either way, but init rereads the file only when no
	// session sits on one of the consoles — a HUP would end the one this run is read on.
	@Test func sharedFilesReloadInitOnlyOffTheConsoles() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				CONSOLE_DEVICES="hvc0 hvc1"
				strip_block() { echo "strip $1"; }
				restore_superseded() { echo "restore $1"; }
				kill() { echo "kill $*"; }
				console_session_device() { printf hvc0; }
				GETTY_MECH=inittab; console_uninstall
				GETTY_MECH=ttys; console_uninstall
				console_session_device() { :; }
				GETTY_MECH=inittab; console_uninstall
				echo "kept=$UNINSTALL_KEPT"
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				strip /etc/inittab
				restore /etc/inittab
				   /etc/inittab changes take effect at the next boot - reloading init now \
				would end this session on hvc0.
				strip /etc/ttys
				restore /etc/ttys
				   /etc/ttys changes take effect at the next boot - reloading init now would \
				end this session on hvc0.
				strip /etc/inittab
				restore /etc/inittab
				kill -HUP 1
				kept=0

				""", "\(shell): \(r.out)")
		}
	}

	// launchd: a loaded job outlives its plist, so the session's own getty is left loaded
	// (gone at the next boot) while the other is booted out; both plists go.
	@Test func launchdLeavesTheSessionsGettyLoaded() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run("""
				UI_COLS=1000
				GETTY_MECH=launchd
				CONSOLE_DEVICES="cu.virtio cu.virtio1"
				LAUNCHD_DIR="$D/LaunchDaemons"
				mkdir -p "$LAUNCHD_DIR"
				for dev in cu.virtio cu.virtio1; do
					printf '<string>%s</string>\\n' "$dev" \\
						> "$LAUNCHD_DIR/$LAUNCHD_GETTY_PREFIX.$dev.plist"
				done
				launchctl() { echo "launchctl $*"; }
				console_session_device() { printf cu.virtio1; }
				console_uninstall
				ls "$LAUNCHD_DIR" | wc -l | tr -d ' '
				""", under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				launchctl bootout system/com.machman.console-getty.cu.virtio
				   cu.virtio1 keeps its login until the next boot - stopping it now would end \
				this session.
				0

				""", "\(shell): \(r.out)")
		}
	}

	// runit stops a service the moment its link goes, so the session's own login stays —
	// named with what to remove — and the uninstall ends partial; the rest goes.
	@Test func runitKeepsTheSessionsServiceAndSaysSo() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=1000
				GETTY_MECH=runit
				CONSOLE_DEVICES="hvc0 hvc1"
				ST_CONSOLE_LOGINS="hvc0 hvc1"
				RUNIT_SV_DIR="$D/sv"
				RUNIT_SERVICE_DIR="$D/service"
				setup() {
					rm -rf "$RUNIT_SV_DIR" "$RUNIT_SERVICE_DIR"
					mkdir -p "$RUNIT_SV_DIR/agetty-hvc0" "$RUNIT_SV_DIR/machman-agetty-hvc1" \
						"$RUNIT_SERVICE_DIR"
					ln -s ../agetty-generic/run "$RUNIT_SV_DIR/agetty-hvc0/run"
					printf '#!/bin/sh\n# %s\nexec agetty -L hvc1 115200 vt100\n' "$MARKER" \
						> "$RUNIT_SV_DIR/machman-agetty-hvc1/run"
					ln -s "$RUNIT_SV_DIR/agetty-hvc0" "$RUNIT_SERVICE_DIR/agetty-hvc0"
					ln -s "$RUNIT_SV_DIR/machman-agetty-hvc1" \
						"$RUNIT_SERVICE_DIR/machman-agetty-hvc1"
					UNINSTALL_KEPT=0
				}
				left() { echo "kept=$UNINSTALL_KEPT $(ls "$RUNIT_SERVICE_DIR" | tr '\n' ' ')"; }
				setup
				console_session_device() { printf hvc1; }
				console_uninstall 2>&1 | sed "s|$D|D|g"
				console_uninstall >/dev/null 2>&1; left
				setup
				console_session_device() { printf hvc0; }
				console_uninstall 2>&1 | sed "s|$D|D|g"
				console_uninstall >/dev/null 2>&1; left
				setup
				console_session_device() { :; }
				console_uninstall; left
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[!!] the login on hvc1 stays (removing it would end this session) - remove \
				D/service/machman-agetty-hvc1 and D/sv/machman-agetty-hvc1 after you log out.
				kept=1 machman-agetty-hvc1 \("")
				[!!] the login on hvc0 stays (removing it would end this session) - remove \
				D/service/agetty-hvc0 after you log out.
				kept=1 agetty-hvc0 \("")
				kept=0 \("")

				""", "\(shell): \(r.out)")
		}
	}

	// The session's console is the terminal of the script or of any ancestor: under sudo's
	// use_pty the script sits on a pts while the login shell is on hvc1. /proc where there
	// is one (a comm may hold ") "), ps elsewhere; nothing over ssh or without consoles.
	@Test func sessionConsoleIsFoundUpTheProcessTree() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				P="$D/proc"
				mk() {
					mkdir -p "$P/$1/fd"
					printf '%s (%s) S %s 1 1\n' "$1" "$2" "$3" > "$P/$1/stat"
					for fd in 0 1 2; do ln -s "$4" "$P/$1/fd/$fd"; done
				}
				CONSOLE_DEVICES="hvc0 hvc1"
				mk $$ sh 9001 /dev/pts/3
				mk 9001 'sudo) S 4 (x' 9002 /dev/pts/3
				mk 9002 sudo 9003 /dev/hvc1
				mk 9003 -bash 1 /dev/hvc1
				echo "sudo on hvc1: [$(console_session_device "$P")]"
				rm -rf "$P/9002" "$P/9003"
				mk 9002 sshd 1 'socket:[77]'
				echo "over ssh: [$(console_session_device "$P")]"
				ps() {
					case "$*" in
					"-o tty= -p $$") echo 'pts/0   ' ;;
					"-o ppid= -p $$") echo '  700' ;;
					"-o tty= -p 700") echo 'ttyV1.0 ' ;;
					"-o ppid= -p 700") echo '    1' ;;
					esac
				}
				CONSOLE_DEVICES="ttyV0.0 ttyV1.0"
				echo "ps: [$(console_session_device "$D/no-proc")]"
				CONSOLE_DEVICES=""
				echo "no consoles: [$(console_session_device "$P")]"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				sudo on hvc1: [hvc1]
				over ssh: []
				ps: [ttyV1.0]
				no consoles: []

				""", "\(shell): \(r.out)")
		}
	}
}
