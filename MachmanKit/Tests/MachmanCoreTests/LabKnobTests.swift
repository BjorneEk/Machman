//
//  LabKnobTests.swift
//  MachmanCoreTests
//
//  The interval knobs a lab run turns (wave r3t, r3-tf): each is the product's own value
//  outside test mode — the .dev suite, the Release suite, no lab at all — and the lab's
//  MACHMAN_LAB_* seconds only under a Debug test suite.
//

import Foundation
import Testing
import MachmanAPI
@testable import MachmanCore

struct LabKnobTests {
	static let dev = "com.gustaffranzen.Machman.dev"
	static let release = "com.gustaffranzen.Machman"
	static let test = "com.gustaffranzen.Machman.test-knob1"

	static func lab(_ suite: String, _ env: [String: String], debug: Bool = true)
		-> LabEnvironment? {
		LabEnvironment(suiteID: suite, environment: env, debugBuild: debug)
	}

	@Test("Q18: the socket keep-alive is an hour outside a lab run")
	func keepAliveDefault() {
		let env = ["MACHMAN_LAB_KEEPALIVE_SECONDS": "2"]
		#expect(MachmanServer.keepAlive(lab: nil) == .seconds(3600))
		#expect(UDSListener.defaultKeepAlive == .seconds(3600))
		#expect(Self.lab(Self.dev, env) == nil)
		#expect(Self.lab(Self.release, env) == nil)
		#expect(Self.lab(Self.test, env, debug: false) == nil)
		#expect(MachmanServer.keepAlive(lab: Self.lab(Self.dev, env)) == .seconds(3600))
		#expect(MachmanServer.keepAlive(lab: Self.lab(Self.release, env)) == .seconds(3600))
		#expect(MachmanServer.keepAlive(lab: Self.lab(Self.test, [:])) == .seconds(3600))
	}

	@Test("Q18: a lab run sets the socket keep-alive from its variable")
	func keepAliveFromLab() {
		func keepAlive(_ value: String) -> DispatchTimeInterval {
			MachmanServer.keepAlive(
				lab: Self.lab(Self.test, ["MACHMAN_LAB_KEEPALIVE_SECONDS": value]))
		}
		#expect(keepAlive("2") == .milliseconds(2000))
		#expect(keepAlive("0.2") == .milliseconds(1000))
		#expect(keepAlive("1.5") == .milliseconds(1500))
		#expect(keepAlive("x") == .seconds(3600))
		#expect(keepAlive("-3") == .seconds(3600))
	}
}
