//
//  LabHarnessTests.swift
//  MachmanLabTests
//
//  L2 harness — the lab's own machinery; runs under scripts/lab.sh in every mode
//

import Foundation
import Testing
import MachmanTestSupport

@Suite("Lab harness", .enabled(if: Lab.runs(.harness)))
struct LabHarnessTests {
	@Test("TC1: lab tiers parse from MACHMAN_LAB_TIERS")
	func tiersParse() {
		#expect(Lab.tiers(from: "harness, smoke,bogus,,l3") == [.harness, .smoke, .l3])
		#expect(Lab.tiers(from: nil).isEmpty)
	}

	@Test("TC1: the lab is active only inside its own run sandbox")
	func activeOnlyInOwnRun() {
		let good = ["MACHMAN_LAB": "1", "MACHMAN_LAB_RUN": "/tmp/mml.ab12"]
		#expect(Lab.isActive(environment: good, token: "ab12"))
		#expect(!Lab.isActive(environment: ["MACHMAN_LAB_RUN": "/tmp/mml.ab12"], token: "ab12"))
		var off = good
		off["MACHMAN_LAB"] = "0"
		#expect(!Lab.isActive(environment: off, token: "ab12"))
		#expect(!Lab.isActive(environment: good, token: "ab123"))
		var test = good
		test["MACHMAN_LAB_RUN"] = "/tmp/mmt.ab12"
		#expect(!Lab.isActive(environment: test, token: "ab12"))
		var slash = good
		slash["MACHMAN_LAB_RUN"] = "/tmp/mml.ab12/"
		#expect(!Lab.isActive(environment: slash, token: "ab12"))
	}
}
