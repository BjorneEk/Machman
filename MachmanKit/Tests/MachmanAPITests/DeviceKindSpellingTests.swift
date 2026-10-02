//
//  DeviceKindSpellingTests.swift
//  MachmanTests
//
//  A7: a device kind this build doesn't know (a newer peer's) decodes as .unknown but keeps
//  its own spelling — so two such devices don't collide on their Identifiable id, and the
//  kind goes back on the wire as it came in, never as "unknown". Kept apart from
//  WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct DeviceKindSpellingTests {
	private func decode(_ json: String) throws -> DeviceInfo {
		try MachmanWire.decoder().decode(DeviceInfo.self, from: Data(json.utf8))
	}

	@Test func unknownKindsDoNotCollide() throws {
		let a = try decode(#"{"enabled":true,"kind":"usbPassthrough"}"#)
		let b = try decode(#"{"enabled":false,"kind":"quantum"}"#)
		#expect(a.kind == .unknown && b.kind == .unknown)
		#expect(a.id != b.id)
	}

	@Test func anUnknownKindIsEchoedInItsOwnSpelling() throws {
		let json = #"{"enabled":true,"kind":"quantum"}"#
		let data = try MachmanWire.encoder().encode(try decode(json))
		#expect(String(decoding: data, as: UTF8.self) == json)
	}

	@Test func kindSpellingNamesIt() throws {
		#expect(try decode(#"{"kind":"usbPassthrough"}"#).kindSpelling == "usbPassthrough")
		#expect(DeviceInfo(kind: .network).kindSpelling == "network")
	}

	@Test func aKnownKindDropsAHeldSpelling() throws {
		var device = try decode(#"{"kind":"quantum"}"#)
		device.kind = .network
		#expect(device.id == "network")
		#expect(device == DeviceInfo(kind: .network))
	}
}
