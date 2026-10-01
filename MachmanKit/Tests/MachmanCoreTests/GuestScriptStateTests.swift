//
//  GuestScriptStateTests.swift
//  MachmanTests
//
//  The guest's state file (30-state): what a run records for the next one — the features it
//  configured and the details their re-runs, --report-only and --uninstall work from. Run
//  for real under every local POSIX shell, with the state dir moved into the probe's
//  scratch dir.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptStateTests {

	// The state dir, moved under $D for every probe.
	static let stateHere = """
		state_paths() { STATE_DIR="$D/state"; STATE_FILE="$STATE_DIR/state.env"; }
		state_paths
		T="$(printf '\\t')"

		"""

	// Values are user text — a mountpoint, a user name, mount names — and come back byte
	// for byte: apostrophes, double quotes, backslashes and tabs included.
	@Test func stateValuesSurviveAnyText() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.stateHere + #"""
				SELECTED_FEATURES="ssh sshfsauto"
				MOUNTPOINT="/mnt/it's \"here\" \\ now"
				SSHFSAUTO_SELECTED="my docs"
				SSHFSAUTO_DONE="my docs${T}@share"
				U="o'brien"
				write_state "ssh sshfsauto"
				read_state
				[ "$ST_MOUNTPOINT" = "$MOUNTPOINT" ] && echo mountpoint
				[ "$ST_AUTOMOUNT_SSHFS" = "$SSHFSAUTO_DONE" ] && echo names
				[ "$ST_SSH_USER" = "$U" ] && echo user
				[ "$ST_CONFIGURED" = "ssh sshfsauto" ] && echo configured
				ls -ln "$STATE_FILE" | cut -c1-10
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "mountpoint\nnames\nuser\nconfigured\n-rw-------\n",
				"\(shell): \(r.out)")
		}
	}

	// S24: a run keeps the record of every feature it did not act on — consoles, the kernel
	// console and its method (the uninstall's grubby path), the SSH user, the sshfs
	// automounts (also when selected with nothing chosen) — while a selected feature's
	// record is this run's.
	@Test func unselectedFeaturesKeepTheirRecords() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.stateHere + #"""
				ST_CONSOLE_LOGINS="hvc0 hvc1"
				ST_KERNEL_CONSOLE=hvc1
				ST_KERNEL_CONSOLE_METHOD=grubby
				ST_SSH_USER=old
				ST_AUTOMOUNT_SSHFS=docs
				ST_MOUNTPOINT=/mnt/m
				show() {
					grep -E '^(CONSOLE_LOGINS|KERNEL_CONSOLE|KERNEL_CONSOLE_METHOD|SSH_USER)=' \
						"$STATE_FILE"
					grep -E '^(AUTOMOUNT_SSHFS|MOUNTPOINT)=' "$STATE_FILE"
					echo --
				}
				SELECTED_FEATURES="ssh sshfsauto"
				U=reg
				write_state "ssh"
				show
				SELECTED_FEATURES="console kernelconsole"
				CONSOLE_MANAGED=hvc0
				U=""
				write_state "console"
				show
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				CONSOLE_LOGINS='hvc0 hvc1'
				KERNEL_CONSOLE='hvc1'
				KERNEL_CONSOLE_METHOD='grubby'
				SSH_USER='reg'
				AUTOMOUNT_SSHFS='docs'
				MOUNTPOINT='/mnt/m'
				--
				CONSOLE_LOGINS='hvc0'
				KERNEL_CONSOLE='hvc1'
				KERNEL_CONSOLE_METHOD='grubby'
				SSH_USER='old'
				AUTOMOUNT_SSHFS='docs'
				MOUNTPOINT='/mnt/m'
				--

				""", "\(shell): \(r.out)")
		}
	}

	// S17: the automounts' names are a TAB-separated list (names carry spaces); a version-1
	// state's space-separated list (names then had none that survived) reads as one.
	@Test func spacedNamesSurviveTheStateFile() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.stateHere + #"""
				SELECTED_FEATURES="sshfsauto"
				SSHFSAUTO_SELECTED=x
				SSHFSAUTO_DONE="my docs${T}@share${T}docs"
				write_state "sshfsauto"
				sed -n 's/^STATE_VERSION=//p' "$STATE_FILE"
				read_state
				printf '%s\n' "$ST_AUTOMOUNT_SSHFS" | tr '\t' '|'
				printf "STATE_VERSION=1\nMARKER='%s'\nAUTOMOUNT_SSHFS='projects docs'\n" \
					"$MARKER" > "$STATE_FILE"
				read_state
				printf '%s\n' "$ST_AUTOMOUNT_SSHFS" | tr '\t' '|'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "2\nmy docs|@share|docs\nprojects|docs\n", "\(shell): \(r.out)")
		}
	}

	// S28: a --report-only run (the boot-time refresh) describes the last real run whole —
	// its status, one-sentence note, failed steps, errors and notes — from the state file,
	// so after a reboot "partial" still says why.
	@Test func reportOnlyReplaysTheLastRun() throws {
		let dir = try GuestScriptHarness.scratch()
		for shell in GuestScriptHarness.shells {
			let run = try GuestScriptHarness.run(Self.stateHere + #"""
				step_failed sshd "could not enable the service"
				report_note report-refresh "rc.local was not executable — re-enabled"
				write_state "ssh"
				"""#, under: shell, in: dir)
			#expect(run.status == 0, "\(shell): \(run.out)")
			let boot = try GuestScriptHarness.run(Self.stateHere + #"""
				read_state
				REPORT_ONLY=1
				FEATURES=""
				state_replay_outcome
				write_report
				grep -E '^(STATUS|FAILED_STEPS|NOTE|ERROR_[0-9]*|NOTE_[0-9]*)=' \
					"$D/GuestReport/report.env"
				"""#, under: shell, in: dir)
			#expect(boot.status == 0, "\(shell): \(boot.out)")
			#expect(boot.out == """
				STATUS=partial
				FAILED_STEPS=sshd
				NOTE=could not enable the service
				ERROR_1=sshd: could not enable the service
				NOTE_1=report-refresh: rc.local was not executable — re-enabled

				""", "\(shell): \(boot.out)")
		}
	}

	// A state file an older script wrote ('…' around raw text, apostrophes unescaped) reads
	// as it was meant.
	@Test func olderStateFilesStillRead() throws {
		for shell in GuestScriptHarness.shells {
			let r = try GuestScriptHarness.run(Self.stateHere + #"""
				mkdir -p "$STATE_DIR"
				printf "STATE_VERSION=1\nSCRIPT_VERSION=4\nMARKER='%s'\n" "$MARKER" > "$STATE_FILE"
				printf "CONFIGURED='ssh sshfsauto'\nLAST_STATUS='ok'\n" >> "$STATE_FILE"
				printf "SSH_USER='reg'\n" >> "$STATE_FILE"
				printf "AUTOMOUNT_SSHFS='docs'\nMOUNTPOINT='/mnt/it's'\n" >> "$STATE_FILE"
				read_state
				printf '%s|%s|%s|%s|%s\n' "$ST_CONFIGURED" "$ST_LAST_STATUS" "$ST_SSH_USER" \
					"$ST_AUTOMOUNT_SSHFS" "$ST_MOUNTPOINT"
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == "ssh sshfsauto|ok|reg|docs|/mnt/it's\n", "\(shell): \(r.out)")
		}
	}
}
