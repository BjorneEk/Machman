//
//  GuestScriptOutputTests.swift
//  MachmanTests
//
//  What the guest setup script prints on a console (05-lib's printers, 90-main's plan
//  lines): folded to the console's width like everything it says. Run for real under every
//  local POSIX shell through GuestScriptHarness, whose runs see an ASCII terminal: no UTF-8
//  locale and no tty, so the ASCII glyphs.
//

import Testing
import Foundation
@testable import MachmanCore

struct GuestScriptOutputTests {

	// S50: a plan line printed its value whole after the 19-column label, so a long one ran
	// past an 80-column console and the terminal broke the two columns apart; the value now
	// folds under its own column, a multi-line value's lines too. The arrow menu's notes
	// stopped two columns past the edge once the mark was ASCII ("[x] " is 4 columns wide,
	// "◉ " 2).
	@Test("S50: a long plan value folds under its label within 80 columns")
	func planValuesFoldUnderTheirColumn() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=80
				plan_line "guest -> host" "set up: ssh mac -> 192.168.64.1 as gustaf (needs \
				approval in Machman), the key pinned"
				plan_line "consoles" "$(printf 'hvc0 (automatic)\nhvc1 (install (systemd))')"
				plan_line "user" "lab -> /home/lab"
				echo ---
				menu_draw 1 "1" \
					"Console logins	hvc2 configured outside Machman - report only - 1 to set up" \
					"Automount the share (virtiofs)	short" \
					| tr -d '\r\033' | sed 's/\[K//; s/\[?25.//'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				  guest -> host    set up: ssh mac -> 192.168.64.1 as gustaf (needs approval
				                   in Machman), the key pinned
				  consoles         hvc0 (automatic)
				                   hvc1 (install (systemd))
				  user             lab -> /home/lab
				---
				  > [x] Console logins                  hvc2 configured outside Machman - report
				    [ ] Automount the share (virtiofs)  short

				""", "\(shell): \(r.out)")
			let wide = r.out.split(separator: "\n").filter { $0.count > 80 }
			#expect(wide.isEmpty, "\(shell): \(wide)")
		}
	}
}
