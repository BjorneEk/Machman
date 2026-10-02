//
//  UniqueNameTests.swift
//  MachmanAPITests
//
//  Q4: the desktop numbered its suggested names in three copies of one loop (a duplicate's
//  “<VM> copy”, a saved safe run's “<VM> saved”, a terminal profile's name). One rule now:
//  the base while it is free, else the first free “<base> N” from 2 up.
//

import Testing
import Foundation
import MachmanAPI

struct UniqueNameTests {
	@Test func aFreeBaseIsItself() {
		#expect(UniqueName.numbered("Debian copy") { _ in false } == "Debian copy")
	}

	@Test func theFirstFreeNumberFollows() {
		let taken: Set = ["Debian copy", "Debian copy 2"]
		#expect(UniqueName.numbered("Debian copy", isTaken: taken.contains) == "Debian copy 3")
	}

	@Test func aGapIsFilledFirst() {
		let taken: Set = ["New Profile", "New Profile 3"]
		#expect(UniqueName.numbered("New Profile", isTaken: taken.contains) == "New Profile 2")
	}
}
