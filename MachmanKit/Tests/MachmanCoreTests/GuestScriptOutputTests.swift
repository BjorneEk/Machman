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

	// S56: a yes/no question and the numbered menus (TERM=dumb, pipes) printed their text
	// whole, so NetBSD's user-mount question ran to 97 columns; they fold like everything
	// said now — the answer still goes after the hint on the question's last line, an item
	// goes on under its number.
	@Test("S56: yes/no questions and numbered menus fold to the console's width")
	func questionsAndNumberedMenusFold() async throws {
		for shell in GuestScriptHarness.shells {
			let r = try await GuestScriptHarness.run(#"""
				UI_COLS=80
				INTERACTIVE=1
				printf 'y\n2\n\n' > "$D/answers"
				exec 3< "$D/answers"
				UI_IN=3
				choices="$(printf '%s\n%s\t%s' short long "a note far longer than any console \
				line could ever hold in a single line")"
				features="$(printf '%s\t%s\n%s\t%s' "Console logins" "hvc2 configured outside \
				Machman - report only - 1 to set up" SSH short)"
				{
					ask_yes_no "Let ANY user of this guest mount filesystems \
				(vfs.generic.usermount=1)? Root can mount without it." n
					echo "<$R_YES>"
					ask_choice 'Which one?' "$choices" 1
					echo "<$R_INDEX>"
					menu_multi 'Set up which?' "$features" 1
					echo "<$R_MARKS>"
				} | sed 's/ *$//'
				"""#, under: shell)
			#expect(r.status == 0, "\(shell): \(r.out)")
			#expect(r.out == """
				Let ANY user of this guest mount filesystems (vfs.generic.usermount=1)? Root
				can mount without it. [y/N] <1>

				Which one?

				  1) short
				  2) long a note far longer than any console line could ever hold in a single
				     line

				Choose [1]: <2>

				Set up which?

				  1) [x] Console logins hvc2 configured outside Machman - report only - 1 to
				         set up
				  2) [ ] SSH short

				Toggle numbers (space-separated), empty keeps the selection: <1>

				""", "\(shell): \(r.out)")
		}
	}
}
