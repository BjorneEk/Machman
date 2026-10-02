//
//  UARTGateMessageTests.swift
//  MachmanCoreTests
//
//  H15: the uart gate's message — shown in the inspector under the gate's header, in the
//  start-time warning toast and in tooltips — opened with "UART unavailable:" under a header
//  saying the same, and cited a private entitlement id no user can act on.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct UARTGateMessageTests {
	private func expectOneSentenceAboutUARTs(_ message: String) {
		#expect(message.contains("UART"))
		#expect(!message.contains("com.apple.private"))
		#expect(!message.hasPrefix("UART unavailable"))
		#expect(message.hasSuffix("."))
		#expect(message.components(separatedBy: ". ").count == 1)
	}

	@Test func theVersionGateSaysSinceWhenWithoutTheEntitlement() throws {
		let gate = try #require(VMConfig.uartUnavailability(gated: true, classPresent: true))
		#expect(gate.reason == .privateUARTGated)
		#expect(gate.sinceOSVersion == SerialPortSupport.privateUARTGatedSinceDisplay)
		#expect(gate.message.contains(SerialPortSupport.privateUARTGatedSinceDisplay))
		expectOneSentenceAboutUARTs(gate.message)
	}

	@Test func aMissingClassSaysSoInOneSentence() throws {
		let gate = try #require(VMConfig.uartUnavailability(gated: false, classPresent: false))
		#expect(gate.reason == .classUnavailable)
		expectOneSentenceAboutUARTs(gate.message)
	}

	@Test func noGateNoMessage() {
		#expect(VMConfig.uartUnavailability(gated: false, classPresent: true) == nil)
	}
}
