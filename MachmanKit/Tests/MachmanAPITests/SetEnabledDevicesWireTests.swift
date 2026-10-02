//
//  SetEnabledDevicesWireTests.swift
//  MachmanTests
//
//  A13: vm.setEnabled's `devices` map (1.0.12) is an additive optional key — present only
//  when a call switches devices, so every older call encodes exactly as before. Kept apart
//  from WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct SetEnabledDevicesWireTests {
	private func encode(_ params: RPCParams.SetEnabled) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(params), as: UTF8.self)
	}

	@Test func devicesTravelByKind() throws {
		#expect(try encode(RPCParams.SetEnabled(name: "Debian", devices: ["network": false]))
			== #"{"devices":{"network":false},"name":"Debian"}"#)
	}

	@Test func noDevicesMeansNoKey() throws {
		#expect(try encode(RPCParams.SetEnabled(name: "Debian", disks: ["d": true]))
			== #"{"disks":{"d":true},"name":"Debian"}"#)
	}

	@Test func anOlderClientsCallDecodes() throws {
		let p = try MachmanWire.decoder().decode(
			RPCParams.SetEnabled.self, from: Data(#"{"name":"Debian","uart":{"0":true}}"#.utf8))
		#expect(p.devices == nil)
		#expect(p.uart == ["0": true])
	}
}
