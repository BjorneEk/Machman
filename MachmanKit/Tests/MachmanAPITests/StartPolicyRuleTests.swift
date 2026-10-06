//
//  StartPolicyRuleTests.swift
//  MachmanAPITests
//
//  Safe mode and Start at login rule each other out (H52): the daemon refuses the pair, and
//  the inspector dims each switch while the other is on with the same sentence. A policy
//  with both on (a hand-edited config) can still switch either one off.
//

import Testing
import MachmanAPI

// L1: a pure rule.
struct StartPolicyRuleTests {
	@Test("H52: a both-on start policy can switch either toggle off")
	func eachSwitchRefusesOnlyWhileTheOtherIsOn() {
		let reason = StartPolicy.safeAutostartRefusal
		#expect(reason == "A safe run can\u{2019}t start automatically")
		#expect(StartPolicy().safeRefusal == nil)
		#expect(StartPolicy().autostartRefusal == nil)
		#expect(StartPolicy(autostart: true).safeRefusal == reason)
		#expect(StartPolicy(autostart: true).autostartRefusal == nil)
		#expect(StartPolicy(safe: true).autostartRefusal == reason)
		#expect(StartPolicy(safe: true).safeRefusal == nil)
		let both = StartPolicy(safe: true, autostart: true)
		#expect(both.safeRefusal == nil && both.autostartRefusal == nil)
	}
}
