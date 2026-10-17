//
//  PulsingRingTests.swift
//  MachmanUITests
//
//  A starting or stopping VM's status dot pulses, unless the user asked macOS for less motion
//  (H66): then the ring stays still. The system setting can't be set in a test (the
//  environment value is read-only), so the ring's look is read for both settings.
//

import Testing
import MachmanTestSupport
@testable import MachmanUI

struct PulsingRingTests {
	@Test("H66: with Reduce Motion the transition ring stays still")
	func reduceMotionStopsThePulse() {
		let still = PulsingRing.look(reduceMotion: true, on: false)
		#expect(still.animation == nil)
		#expect(PulsingRing.look(reduceMotion: true, on: true).opacity == still.opacity)
		let pulse = PulsingRing.look(reduceMotion: false, on: true)
		#expect(pulse.animation != nil)
		#expect(pulse.opacity != PulsingRing.look(reduceMotion: false, on: false).opacity)
	}
}
