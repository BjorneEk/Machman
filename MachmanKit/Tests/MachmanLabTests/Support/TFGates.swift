//
//  TFGates.swift
//  MachmanLabTests
//
//  The engine suites' opt-ins (wave r3t, B-1 and B-2). Both variables are MACHMAN_LAB_*, so
//  the lab agent gets them too: the agent's own local-network guard (SSHDiscovery's probe)
//  reads the same one.
//  - Local network (B-1): no TCP from the lab agent, a vmhost or a test process to a guest on
//    the VM network unless MACHMAN_LAB_LOCAL_NETWORK=1 — the agent's macOS Local Network
//    privacy prompt. Off by default; such tests skip with the reason.
//  - Second volumes (B-2): disk-image volumes may raise a one-time Removable Volumes prompt,
//    which the user accepted. On by default; MACHMAN_LAB_VOLUMES=0 opts out.
//

import Foundation
import MachmanAPI
import Testing

enum TFGate {
	static func localNetwork(_ environment: [String: String]) -> Bool {
		environment["MACHMAN_LAB_LOCAL_NETWORK"] == "1"
	}

	static func volumes(_ environment: [String: String]) -> Bool {
		environment["MACHMAN_LAB_VOLUMES"] != "0"
	}

	static var localNetwork: Bool { localNetwork(Lab.environment) }
	static var volumes: Bool { volumes(Lab.environment) }

	static let localNetworkReason = Comment(
		rawValue: "Deferred: local network (opt-in MACHMAN_LAB_LOCAL_NETWORK=1)")
	static let volumesReason = Comment(
		rawValue: "second volumes are off (MACHMAN_LAB_VOLUMES=0)")

	/// This Mac rejects the private UART classes, so a uart port starts without being attached.
	static func uartGated(_ version: OperatingSystemVersion) -> Bool {
		let gate = SerialPortSupport.privateUARTGatedSince
		return (version.majorVersion, version.minorVersion, version.patchVersion)
			>= (gate.majorVersion, gate.minorVersion, gate.patchVersion)
	}

	static var uartGated: Bool { uartGated(ProcessInfo.processInfo.operatingSystemVersion) }

	static let uartReason = Comment(
		rawValue: "this Mac attaches UART ports (macOS before "
			+ "\(SerialPortSupport.privateUARTGatedSinceDisplay)), so nothing is dropped")
}
