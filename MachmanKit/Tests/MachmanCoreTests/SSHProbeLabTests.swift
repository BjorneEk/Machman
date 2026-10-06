//
//  SSHProbeLabTests.swift
//  MachmanCoreTests
//
//  Under a test suite the agent opens no TCP connection to a guest unless the lab run opted
//  into the local network (MACHMAN_LAB_LOCAL_NETWORK=1): a connect to the VM network can raise
//  macOS's Local Network prompt, which the host-quiet contract forbids. Outside test mode the
//  probe is today's.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SSHProbeLabTests {
	private static func lab(_ environment: [String: String] = [:]) -> LabEnvironment? {
		LabEnvironment(
			suiteID: "com.gustaffranzen.Machman.test-abc1", environment: environment,
			debugBuild: true)
	}

	@Test("Q18: outside test mode every guest address may be probed")
	func outsideTestModeEveryAddressMayBeProbed() {
		#expect(SSHDiscovery.probeAllowed(host: "192.168.64.5", lab: nil))
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let none = LabEnvironment(
				suiteID: suite, environment: ["MACHMAN_LAB_LOCAL_NETWORK": "0"], debugBuild: true)
			#expect(none == nil)
			#expect(SSHDiscovery.probeAllowed(host: "192.168.64.5", lab: none))
		}
	}

	@Test("Q18: a lab run probes no guest on the VM network unless it opted in")
	func aLabRunProbesNoGuestUnlessItOptedIn() throws {
		let quiet = try #require(Self.lab())
		#expect(!quiet.allowsLocalNetwork)
		#expect(!SSHDiscovery.probeAllowed(host: "192.168.64.5", lab: quiet))
		#expect(!SSHDiscovery.probeAllowed(host: "10.0.2.15", lab: quiet))
		#expect(!SSHDiscovery.probeAllowed(host: Self.testNet, lab: quiet))
		#expect(SSHDiscovery.probeAllowed(host: "127.0.0.1", lab: quiet))
		#expect(SSHDiscovery.probeAllowed(host: "::1", lab: quiet))
		let open = try #require(Self.lab(["MACHMAN_LAB_LOCAL_NETWORK": "1"]))
		#expect(open.allowsLocalNetwork)
		#expect(SSHDiscovery.probeAllowed(host: "192.168.64.5", lab: open))
	}

	// TEST-NET-1 (RFC 5737): refused like any guest address, and on no local subnet, so a
	// regressed seam makes this test time out and fail, never open a Local Network connect.
	static let testNet = "192.0.2.1"

	@Test("Q18: a refused probe reads as closed without connecting")
	func aRefusedProbeReadsAsClosed() async {
		// Only meaningful inside a test-mode process (scripts/test.sh's suite is one).
		guard let current = LabEnvironment.current, !current.allowsLocalNetwork else { return }
		let start = Date()
		#expect(await SSHDiscovery.probeTCP(host: Self.testNet, timeout: 5) == false)
		#expect(Date().timeIntervalSince(start) < 1)
	}
}
