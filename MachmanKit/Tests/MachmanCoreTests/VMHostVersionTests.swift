//
//  VMHostVersionTests.swift
//  MachmanTests
//
//  E22: a vmhost reports its OWN bundle version in hello, not the spawning daemon's (which may
//  be older or newer than the binary it launched) — and a launch-agent host, which gets no
//  environment at all, no longer reports "dev". The daemon's version floor reads this value.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct VMHostVersionTests {
	@Test func theBundleWins() {
		#expect(VMHostVersion.current(
			bundleInfo: ["CFBundleShortVersionString": "1.0.12"],
			environment: ["MACHMAN_VERSION": "1.0.9"]) == "1.0.12")
	}

	@Test func theEnvironmentIsAFallback() {
		#expect(VMHostVersion.current(
			bundleInfo: nil, environment: ["MACHMAN_VERSION": "1.0.9"]) == "1.0.9")
		#expect(VMHostVersion.current(
			bundleInfo: ["CFBundleShortVersionString": ""],
			environment: ["MACHMAN_VERSION": "1.0.9"]) == "1.0.9")
	}

	// A launch agent passes nothing: such a host reads "dev", which every versioned daemon
	// counts as older than itself.
	@Test func nothingReadsDev() {
		#expect(VMHostVersion.current(bundleInfo: nil, environment: [:]) == "dev")
		#expect(MachmanVersion.isOlder("dev-vmhost", than: "1.0.12"))
	}
}
