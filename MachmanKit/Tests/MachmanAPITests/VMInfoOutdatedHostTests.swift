//
//  VMInfoOutdatedHostTests.swift
//  MachmanTests
//
//  VMInfo.outdatedHost (E22, 1.0.12) is an additive daemon overlay: present only while an
//  older vmhost still runs the VM, omitted otherwise, and absent from older daemons'
//  payloads. Kept apart from WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct VMInfoOutdatedHostTests {
	private func sample(outdatedHost: Bool?) -> VMInfo {
		VMInfo(
			name: "alpha", state: .running, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			outdatedHost: outdatedHost)
	}

	@Test func theMarkRoundTrips() throws {
		let data = try MachmanWire.encoder().encode(sample(outdatedHost: true))
		#expect(String(decoding: data, as: UTF8.self).contains(#""outdatedHost":true"#))
		let decoded = try MachmanWire.decoder().decode(VMInfo.self, from: data)
		#expect(decoded.outdatedHost == true)
	}

	@Test func aCurrentHostOmitsTheKey() throws {
		let data = try MachmanWire.encoder().encode(sample(outdatedHost: nil))
		#expect(!String(decoding: data, as: UTF8.self).contains("outdatedHost"))
		#expect(try MachmanWire.decoder().decode(VMInfo.self, from: data).outdatedHost == nil)
	}

	@Test func anOlderDaemonsPayloadDecodesAsCurrent() throws {
		let legacy = #"""
			{"name":"alpha","state":"running","created":"2023-11-14T22:13:20Z","cpuCount":2,
			"memoryBytes":2147483648,"disks":[],"mounts":[],"boot":{"mode":"efi"},
			"windowOpen":false}
			"""#
		let decoded = try MachmanWire.decoder().decode(VMInfo.self, from: Data(legacy.utf8))
		#expect(decoded.outdatedHost == nil)
	}
}
