//
//  VMInfoUnresponsiveTests.swift
//  MachmanTests
//
//  VMInfo.unresponsive (E20) is an additive daemon overlay: present only while a vmhost
//  misses its answer deadline, omitted otherwise, and absent from older daemons' payloads.
//  Kept apart from WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct VMInfoUnresponsiveTests {
	private func sample(unresponsive: Bool?) -> VMInfo {
		VMInfo(
			name: "alpha", state: .running, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			unresponsive: unresponsive)
	}

	@Test func theMarkRoundTrips() throws {
		let data = try MachmanWire.encoder().encode(sample(unresponsive: true))
		#expect(String(decoding: data, as: UTF8.self).contains(#""unresponsive":true"#))
		let decoded = try MachmanWire.decoder().decode(VMInfo.self, from: data)
		#expect(decoded.unresponsive == true)
		#expect(decoded.isUnresponsive)
	}

	@Test func anAnsweringVMOmitsTheKey() throws {
		let data = try MachmanWire.encoder().encode(sample(unresponsive: nil))
		#expect(!String(decoding: data, as: UTF8.self).contains("unresponsive"))
		let decoded = try MachmanWire.decoder().decode(VMInfo.self, from: data)
		#expect(decoded.unresponsive == nil)
		#expect(!decoded.isUnresponsive)
	}

	@Test func anOlderDaemonsPayloadDecodesAsAnswering() throws {
		let legacy = #"""
			{"name":"alpha","state":"running","created":"2023-11-14T22:13:20Z","cpuCount":2,
			"memoryBytes":2147483648,"disks":[],"mounts":[],"boot":{"mode":"efi"},
			"windowOpen":false}
			"""#
		let decoded = try MachmanWire.decoder().decode(VMInfo.self, from: Data(legacy.utf8))
		#expect(decoded.unresponsive == nil)
		#expect(!decoded.isUnresponsive)
	}

	@Test func falseIsNotUnresponsive() {
		#expect(!sample(unresponsive: false).isUnresponsive)
	}
}
