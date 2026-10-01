//
//  GuestScriptReportTests.swift
//  MachmanTests
//
//  What the guest setup script reports (80-report) — the AUTOMOUNT_, ERROR_ and NOTE_
//  rows the host parses, and what a --report-only run rebuilds from the state file — run
//  for real under every local POSIX shell through GuestScriptHarness.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptReportTests {

	// S9: a --report-only run lists the share's sshfs automount where its entry mounts it
	// (the share root, as sshfsauto_entry does), every other mount under the mount root.
	@Test func shareRowKeepsTheShareRoot() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				ST_AUTOMOUNT_SSHFS="@share${T}docs"
				ST_MOUNTPOINT=/mnt/machman/mounts
				automount_lines_kept
				printf '%s\n' "$AUTOMOUNT_LINES" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				sshfs|@share|/mnt/machman/share
				sshfs|docs|/mnt/machman/mounts/docs

				""", "\(shell): \(r.out)")
		}
	}

	// S14: systemd's sshfs automounts are started right after the reload that creates their
	// units, so the folders mount on first access without a reboot — and the run says so
	// only for those it armed; without systemd-escape they arm at the next boot.
	@Test func automountsArmNow() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				INIT=systemd
				U="$(id -un)"
				GROUP="$(id -gn)"
				HOME_DIR="$D/home"
				MOUNTPOINT="$D/mounts"
				GATEWAY=192.168.64.1
				MOUNTS_SSHFS="docs${T}/Users/g/Docs"
				SSHFSAUTO_SELECTED=docs
				UI_COLS=200
				put_block() { return 0; }
				systemctl() { printf 'systemctl %s\n' "$*" >> "$D/log"; }
				mkdir -p "$D/bin"
				printf '#!/bin/sh\necho "escape $*" >> "%s/log"\necho mnt-docs.automount\n' \
					"$D" > "$D/bin/systemd-escape"
				chmod 755 "$D/bin/systemd-escape"
				SYSTEM_PATH="$PATH"
				PATH="$D/bin:$PATH"
				sshfsauto_act 2>&1 | grep -v connect
				PATH="$SYSTEM_PATH"
				sed "s|$D|D|" "$D/log"
				rm -f "$D/log"
				sshfsauto_act 2>&1 | grep -v connect
				sed "s|$D|D|" "$D/log"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				[ok] sshfs automounts armed (docs) — each mounts on first access
				systemctl daemon-reload
				escape -p --suffix=automount -- D/mounts/docs
				systemctl start mnt-docs.automount
				[!!] sshfs automounts (docs) are armed at the next boot
				systemctl daemon-reload

				""", "\(shell): \(r.out)")
		}
	}

	// S36: a note (a repair made, a boot refresh that will not run) is reported as NOTE_<n>,
	// after the errors, and is no error: a clean run's report carries no ERROR_ line.
	@Test func reportNotesTravelAsNotes() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				FEATURES=""
				report_note report-refresh "rc.local was not executable — re-enabled"
				step_failed sshd "could not enable the service"
				write_report
				grep -E '^(STATUS|ERROR_|NOTE_)' "$D/GuestReport/report.env"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out.hasSuffix("""
				STATUS=partial
				ERROR_1=sshd: could not enable the service
				NOTE_1=report-refresh: rc.local was not executable — re-enabled

				"""), "\(shell): \(r.out)")
		}
	}

	// S17: a row whose name has a space is TAB-separated, so the host reads it whole; every
	// other row stays space-separated, as every daemon reads it. The feature's detail lists
	// the names comma-separated.
	@Test func reportRowsKeepSpacedNamesWhole() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(#"""
				T="$(printf '\t')"
				FEATURES=sshfsauto
				avail_sshfsauto=1
				SSHFSAUTO_DONE="my docs${T}docs"
				AUTOMOUNT_LINES="sshfs${T}my docs${T}/mnt/machman/mounts/my docs
				sshfs${T}docs${T}/mnt/machman/mounts/docs"
				write_report
				grep -E '^(AUTOMOUNT_|FEATURE_)' "$D/GuestReport/report.env" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				FEATURE_sshfsAutomount=configured my docs, docs
				AUTOMOUNT_1=sshfs|my docs|/mnt/machman/mounts/my docs
				AUTOMOUNT_2=sshfs docs /mnt/machman/mounts/docs

				""", "\(shell): \(r.out)")
		}
	}
}
