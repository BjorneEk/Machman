//
//  VMPickerKeysTests.swift
//  MachmanDesktopCoreTests
//
//  H49 (C10): the VM picker's search field narrowed the list but couldn't pick. Return
//  opens the highlighted row, else the first match; ↑/↓ move the highlight and stop at the
//  ends; typing puts it back on the first match. The keys themselves need a key window
//  (manual row); this is the rule they drive.
//

import Testing
@testable import MachmanDesktopCore

struct VMPickerKeysTests {
	@Test("H49: Return opens the first match and the arrows move the highlight")
	func returnOpensTheFirstMatchAndArrowsMove() {
		let all = ["Debian", "Sequoia", "Kernel Lab", "Fedora", "Alpine"]
		var keys = VMPickerKeys()
		// Nothing typed or moved: Return opens the first VM, nothing is highlighted yet.
		#expect(keys.highlighted == nil)
		#expect(keys.pick(in: all) == "Debian")
		// ↓ from nothing lands on the first row, ↑ from nothing on the last.
		keys.move(1, in: all)
		#expect(keys.highlighted == "Debian")
		keys.move(1, in: all)
		keys.move(1, in: all)
		#expect(keys.pick(in: all) == "Kernel Lab")
		var up = VMPickerKeys()
		up.move(-1, in: all)
		#expect(up.highlighted == "Alpine")
		// The ends hold.
		up.move(1, in: all)
		#expect(up.highlighted == "Alpine")

		// Typing narrows the list and puts the highlight on the first match.
		let matches = ["Fedora", "Debian"].filter { $0.localizedCaseInsensitiveContains("e") }
		keys.queryChanged("e", matches: matches)
		#expect(keys.highlighted == "Fedora")
		#expect(keys.pick(in: matches) == "Fedora")
		keys.move(1, in: matches)
		keys.move(1, in: matches)
		#expect(keys.pick(in: matches) == "Debian")
		// Cleared again: no highlight, and no match means nothing to open.
		keys.queryChanged("", matches: all)
		#expect(keys.highlighted == nil)
		keys.queryChanged("zzz", matches: [])
		#expect(keys.pick(in: []) == nil)
		keys.move(1, in: [])
		#expect(keys.highlighted == nil)
	}
}
