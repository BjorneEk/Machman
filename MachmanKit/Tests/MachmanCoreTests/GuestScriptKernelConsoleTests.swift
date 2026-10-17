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

	// Boot entries as files in $GRUBBY_DIR (line 1 the kernel, line 2 its arguments), edited
	// the way BLS grubby edits them; --update-kernel takes ALL or one entry's kernel.
	// entry <file> <kernel> <arguments> makes one; args <file> prints its arguments.
	static let grubby = #"""
		mkdir -p "$D/bin" "$D/entries"
		cat > "$D/bin/grubby" <<'SH'
		#!/bin/sh
		target=ALL
		for a in "$@"; do
			case "$a" in --update-kernel=*) target="${a#--update-kernel=}" ;; esac
		done
		# drop <file> <key|value> <match>: the entry without its first argument that matches.
		drop() {
			awk -v by="$2" -v m="$3" 'NR == 1 { print; next } {
				o = ""
				for (i = 1; i <= NF; i++) {
					k = $i; if (by == "key") sub(/=.*/, "", k)
					if (!d && k == m) { d = 1; continue }
					o = o (o ? " " : "") $i
				}
				print o
			}' "$1" > "$1.t" && mv "$1.t" "$1"
		}
		n=0
		for f in "$GRUBBY_DIR"/*; do
			kernel="$(sed -n 1p "$f")"
			for a in "$@"; do
				[ "$a" != --info=ALL ] || printf 'index=%s\nkernel="%s"\nargs="%s"\n' \
					"$n" "$kernel" "$(sed -n 2p "$f")"
			done
			n=$((n + 1))
			[ "$target" = ALL ] || [ "$target" = "$kernel" ] || continue
			for a in "$@"; do
				case "$a" in
				--args=*)
					for x in ${a#--args=}; do drop "$f" key "${x%%=*}"; done
					printf '%s\n%s\n' "$kernel" "$(sed -n 2p "$f") ${a#--args=}" \
						| sed '2s/^ //' > "$f.t"
					mv "$f.t" "$f"
					;;
				--remove-args=*) for x in ${a#--remove-args=}; do drop "$f" value "$x"; done ;;
				esac
			done
		done
		SH
		chmod 755 "$D/bin/grubby"
		PATH="$D/bin:$PATH"
		GRUBBY_DIR="$D/entries"
		export GRUBBY_DIR
		entry() { printf '%s\n%s\n' "$2" "$3" > "$GRUBBY_DIR/$1"; }
		args() { sed -n 2p "$GRUBBY_DIR/$1"; }

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
				K=/boot/vmlinuz-6.9
				entries() { entry 0 "$K" "$1"; }
				pointed() {
					KC_DEVICE="$1"
					kernelconsole_act
					write_state kernelconsole
					read_state
					LEDGER_DONE=""
				}
				uninstalled() {
					kernelconsole_uninstall
					echo "uninstalled: $(args 0)"
				}
				entries "ro console=tty0 quiet"
				pointed hvc0
				echo "set: $(args 0)"
				uninstalled
				echo ---
				rm -f "$STATE_FILE"
				ST_LEDGER=""
				entries "ro console=ttyS0,115200 console=tty0 quiet"
				pointed hvc0
				echo "set: $(args 0)"
				uninstalled
				echo ---
				rm -f "$STATE_FILE"
				ST_LEDGER=""
				ST_KERNEL_CONSOLE=""
				entries "ro console=tty0 quiet"
				pointed hvc0 >/dev/null
				pointed hvc1 >/dev/null
				echo "re-pointed: $(args 0)"
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
				echo "v7 record: $(args 0)"
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
				[ok] put back console=ttyS0,115200 in the boot entry for /boot/vmlinuz-6.9
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

	// S60: the restore cleared every console= argument the entries held at uninstall and put
	// the pre-setup list into every entry. Now each entry gets back only what it lost, and
	// only while its console= arguments are its old ones: one the user added since stays and
	// the lost one is named (the last console= is /dev/console, so the order is theirs). An
	// entry that never had the list (a rescue entry) gains nothing and loses what setup put
	// in it; one made since (a new kernel copying the options) loses the device argument.
	@Test("S60: the uninstall restores per entry and keeps a console= added since setup")
	func uninstallRestoresEachEntryOnItsOwn() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(
				GuestScriptStateTests.stateHere + Self.grubby + #"""
				UI_COLS=1000
				OS=Linux
				BOOTLOADER=grubby
				CONSOLE_DEVICES="hvc0 hvc1"
				SELECTED_FEATURES=kernelconsole
				entry 0 /boot/vmlinuz-6.9 "ro console=ttyS0,115200 quiet"
				entry 1 /boot/vmlinuz-0-rescue "ro quiet"
				KC_DEVICE=hvc0
				kernelconsole_act >/dev/null
				write_state kernelconsole
				read_state
				LEDGER_DONE=""
				grubby --update-kernel=/boot/vmlinuz-6.9 --args=console=ttyAMA0
				entry 2 /boot/vmlinuz-7.0 "ro quiet console=hvc0 console=tty0"
				kernelconsole_uninstall
				for n in 0 1 2; do echo "$n: $(args "$n")"; done
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				   console=ttyS0,115200 stays out of the boot entry for /boot/vmlinuz-6.9 - it \
				has console arguments set since, and the last console= is /dev/console.
				   Add it back where it belongs: grubby --update-kernel=/boot/vmlinuz-6.9 \
				--args='console=ttyS0,115200'
				0: ro quiet console=ttyAMA0
				1: ro quiet
				2: ro quiet console=tty0

				""", "\(shell): \(r.out)")
		}
	}

	// S60: the ledger reached the state only at the run's end, so a run that stopped after its
	// kernel-console act lost its record — the re-run found the arguments and called them the
	// entries' own, and the uninstall left console=hvc0 in and console=ttyS0 out for good. Once
	// a run acts, every ledger entry reaches the state as it is made, and the uninstall takes
	// the grubby path from the record alone.
	@Test("S60: a run that stops after its kernel-console act keeps its record for the uninstall")
	func aStoppedRunKeepsItsKernelConsoleRecord() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(
				GuestScriptStateTests.stateHere + Self.grubby + #"""
				UI_COLS=1000
				OS=Linux
				BOOTLOADER=grubby
				CONSOLE_DEVICES="hvc0 hvc1"
				SELECTED_FEATURES=kernelconsole
				entry 0 /boot/vmlinuz-6.9 "ro console=ttyS0,115200 console=tty0 quiet"
				PREFLIGHT_DONE=1
				KC_DEVICE=hvc0
				kernelconsole_act >/dev/null
				echo "set: $(args 0)"
				sed -n 's/^LEDGER_[0-9]*=//p' "$STATE_FILE"
				PREFLIGHT_DONE=0
				LEDGER_DONE=""
				ST_LEDGER=""
				read_state
				kernelconsole_uninstall
				echo "uninstalled: $(args 0)"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				set: ro quiet console=hvc0 console=tty0
				'grubby-device hvc0'
				'grubby-entry /boot/vmlinuz-6.9'
				'grubby-arg /boot/vmlinuz-6.9 console=hvc0'
				'grubby-had /boot/vmlinuz-6.9 console=ttyS0,115200 console=tty0'
				[ok] put back console=ttyS0,115200 in the boot entry for /boot/vmlinuz-6.9
				uninstalled: ro quiet console=ttyS0,115200 console=tty0

				""", "\(shell): \(r.out)")
		}
	}
}
