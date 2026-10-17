//
//  GuestScriptKernelConsoleTests.swift
//  MachmanTests
//
//  The kernel console's boot-entry edits (45-kernel-console) over a grubby stand-in that
//  keeps BLS grubby's argument rules — an added argument first drops the entry's first one
//  with its key, a removed one goes by exact value (both measured on Fedora's grubby) — run
//  for real under every local POSIX shell through GuestScriptHarness.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptKernelConsoleTests {

	// One boot entry, its arguments in $GRUBBY_ARGS, edited the way BLS grubby edits them.
	static let grubby = #"""
		mkdir -p "$D/bin"
		cat > "$D/bin/grubby" <<'SH'
		#!/bin/sh
		f="$GRUBBY_ARGS"
		# drop <key|value> <match>: the entry without its first argument that matches.
		drop() {
			awk -v by="$1" -v m="$2" '{
				for (i = 1; i <= NF; i++) {
					k = $i; if (by == "key") sub(/=.*/, "", k)
					if (!d && k == m) { d = 1; continue }
					o = o (o ? " " : "") $i
				}
				print o
			}' "$f" > "$f.t" && mv "$f.t" "$f"
		}
		for a in "$@"; do
			case "$a" in
			--info=ALL) printf 'index=0\nargs="%s"\n' "$(cat "$f")" ;;
			--args=*)
				for x in ${a#--args=}; do drop key "${x%%=*}"; done
				printf '%s %s\n' "$(cat "$f")" "${a#--args=}" | sed 's/^ //' > "$f.t"
				mv "$f.t" "$f"
				;;
			--remove-args=*) for x in ${a#--remove-args=}; do drop value "$x"; done ;;
			esac
		done
		SH
		chmod 755 "$D/bin/grubby"
		PATH="$D/bin:$PATH"
		GRUBBY_ARGS="$D/args"
		export GRUBBY_ARGS

		"""#

	// S60: the uninstall (and setup's re-point) removed "console=<dev> console=tty0" by
	// value, so a console=tty0 the boot entries had before setup went too — and grubby's add
	// had already dropped every console= argument they carried. A run now records what it
	// added and the console= list grubby replaced; the uninstall removes only the former and
	// puts the latter back in its order. A record from before v8 removes the device's
	// argument and names console=tty0, which may be the entries' own.
	@Test("S60: the uninstall keeps a console=tty0 the boot entries had before setup")
	func uninstallKeepsWhatTheEntriesHad() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(
				GuestScriptStateTests.stateHere + Self.grubby + #"""
				UI_COLS=1000
				OS=Linux
				BOOTLOADER=grubby
				CONSOLE_DEVICES="hvc0 hvc1"
				SELECTED_FEATURES=kernelconsole
				entries() { printf '%s\n' "$1" > "$GRUBBY_ARGS"; }
				pointed() {
					KC_DEVICE="$1"
					kernelconsole_act
					write_state kernelconsole
					read_state
					LEDGER_DONE=""
				}
				uninstalled() {
					kernelconsole_uninstall
					echo "uninstalled: $(cat "$GRUBBY_ARGS")"
				}
				entries "ro console=tty0 quiet"
				pointed hvc0
				echo "set: $(cat "$GRUBBY_ARGS")"
				uninstalled
				echo ---
				rm -f "$STATE_FILE"
				ST_LEDGER=""
				entries "ro console=ttyS0,115200 console=tty0 quiet"
				pointed hvc0
				echo "set: $(cat "$GRUBBY_ARGS")"
				uninstalled
				echo ---
				rm -f "$STATE_FILE"
				ST_LEDGER=""
				ST_KERNEL_CONSOLE=""
				entries "ro console=tty0 quiet"
				pointed hvc0 >/dev/null
				pointed hvc1 >/dev/null
				echo "re-pointed: $(cat "$GRUBBY_ARGS")"
				uninstalled
				echo ---
				entries "ro quiet console=hvc0 console=tty0"
				{
					echo "SCRIPT_VERSION=7"
					echo "MARKER='$MARKER'"
					echo "KERNEL_CONSOLE='hvc0'"
					echo "KERNEL_CONSOLE_METHOD='grubby'"
				} > "$STATE_FILE"
				read_state
				kernelconsole_uninstall
				echo "v7 record: $(cat "$GRUBBY_ARGS")"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] kernel messages -> hvc0, display stays on tty0 (next boot)
				   Rollback: grubby --update-kernel=ALL --remove-args='console=hvc0'
				set: ro quiet console=hvc0 console=tty0
				uninstalled: ro quiet console=tty0
				---
				[ok] kernel messages -> hvc0, display stays on tty0 (next boot)
				   grubby replaced console=ttyS0,115200 in the boot entries - the uninstall \
				puts it back.
				   Rollback: grubby --update-kernel=ALL --remove-args='console=hvc0'
				set: ro quiet console=hvc0 console=tty0
				[ok] put back console=ttyS0,115200 console=tty0 in the boot entries
				uninstalled: ro quiet console=ttyS0,115200 console=tty0
				---
				re-pointed: ro quiet console=hvc1 console=tty0
				uninstalled: ro quiet console=tty0
				---
				   console=tty0 stays in the boot entries - no record says Machman added it.
				   Remove it: grubby --update-kernel=ALL --remove-args='console=tty0'
				v7 record: ro quiet console=tty0

				""", "\(shell): \(r.out)")
		}
	}
}
