//
//  MenuRulesTests.swift
//  MachmanDesktopCoreTests
//
//  The menu rules every surface shares (VMMenuRules). P14: what the daemon refuses on a
//  running VM (RoutingMachman.requireStopped) is offered disabled with a one-sentence reason
//  while the VM is hosted — running, starting or not answering — and offered plainly
//  otherwise.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MenuRulesTests {
	@Test func everyStopFirstActionIsRefusedWhileRunning() {
		let hosted = [
			Samples.linux("Debian", state: .running), Samples.linux("Debian", state: .starting),
			Samples.notResponding(),
		]
		for vm in hosted {
			for action in StoppedOnly.allCases {
				#expect(vm.refusal(action) == action.stopFirst, "\(vm.state) \(action)")
			}
		}
		let stopped = [Samples.linux("Alpine"), Samples.linux("Fedora", state: .error)]
		for vm in stopped {
			for action in StoppedOnly.allCases {
				#expect(vm.refusal(action) == nil, "\(vm.state) \(action)")
			}
		}
	}

	// Decision 16: a tooltip is one short sentence.
	@Test func reasonsAreOneShortSentence() {
		for action in StoppedOnly.allCases {
			let reason = action.stopFirst
			#expect(reason.hasPrefix("Stop the VM to "), "\(reason)")
			#expect(!reason.hasSuffix("."), "\(reason)")
			#expect(reason.count <= 60, "\(reason)")
		}
	}
}
