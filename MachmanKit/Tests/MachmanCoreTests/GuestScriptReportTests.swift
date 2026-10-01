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
}
