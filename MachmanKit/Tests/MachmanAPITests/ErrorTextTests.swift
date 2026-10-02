//
//  ErrorTextTests.swift
//  MachmanTests
//
//  E28: failed operation cards showed Swift struct dumps ("MachmanError(code: …)") and NSError
//  dumps ("Error Domain=… Code=…"). MachmanError describes itself by its message, and
//  MachmanError.userMessage is the one rule every user-facing path shows an error by. The
//  encoding stays code + message (a new pin, apart from WireFixtureTests).
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct ErrorTextTests {
	private let refusal = MachmanError(code: .invalidArgument, message: "x")

	@Test func aMachmanErrorDescribesItselfByItsMessage() {
		#expect("\(refusal)" == "x")
		#expect(refusal.localizedDescription == "x")
		#expect(String(reflecting: refusal).contains("invalidArgument"))
		#expect(!"\(refusal)".contains("MachmanError("))
	}

	@Test func theEncodingIsStillCodeAndMessage() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let json = String(decoding: try encoder.encode(refusal), as: UTF8.self)
		#expect(json == #"{"code":"invalidArgument","message":"x"}"#)
	}

	// Virtualization's install failure says why only in its failure reason.
	@Test func anNSErrorShowsItsDescriptionAndReason() {
		let error = NSError(domain: "VZErrorDomain", code: 10007, userInfo: [
			NSLocalizedDescriptionKey: "Installation failed.",
			NSLocalizedFailureReasonErrorKey:
				"A software update is required to complete the installation.",
		])
		#expect(MachmanError.userMessage(for: error)
			== "Installation failed. A software update is required to complete the installation.")
	}

	// Foundation composes a CocoaError's own reason into its description: no second copy.
	@Test func aCocoaErrorShowsItsDescriptionOnce() {
		let error = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/x/big.raw"])
		let text = MachmanError.userMessage(for: error)
		#expect(text == error.localizedDescription)
		#expect(!text.contains("Error Domain"))
	}

	@Test func aSwiftErrorShowsItsOwnDescription() {
		enum Refusal: Error, CustomStringConvertible {
			case gone
			var description: String { "the socket is gone" }
		}
		#expect(MachmanError.userMessage(for: Refusal.gone) == "the socket is gone")
		#expect(MachmanError.userMessage(for: refusal) == "x")
		#expect(MachmanError.userMessage(for: CancellationError()) == "Canceled")
	}
}
