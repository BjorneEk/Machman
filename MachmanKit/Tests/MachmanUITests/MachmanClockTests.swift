//
//  MachmanClockTests.swift
//  MachmanUITests
//
//  Counted time reads MachmanClock (Q16): the renders pin it, the app never does, so its
//  default must stay the wall clock.
//

import Testing
import Foundation
import MachmanUI

struct MachmanClockTests {
	@Test func theDefaultIsTheWallClock() {
		let before = Date()
		let now = MachmanClock.now()
		#expect(now >= before && now <= Date())
	}
}
