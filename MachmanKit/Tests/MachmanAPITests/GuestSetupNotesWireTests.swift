//
//  GuestSetupNotesWireTests.swift
//  MachmanTests
//
//  GuestSetupInfo.notes (S36) is additive: informational lines a setup run reported, in the
//  errors' {step, message} shape, omitted when there are none and absent from older
//  daemons' payloads. Kept apart from WireFixtureTests, whose pinned fixtures must stay
//  byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct GuestSetupNotesWireTests {
	@Test func notesTravelInTheErrorsShape() throws {
		let info = GuestSetupInfo(
			installed: true,
			notes: [GuestSetupNote(step: "report-refresh", message: "re-enabled rc.local")])
		let json = String(decoding: try MachmanWire.encoder().encode(info), as: UTF8.self)
		#expect(json.contains(
			#""notes":[{"message":"re-enabled rc.local","step":"report-refresh"}]"#))
		let back = try MachmanWire.decoder().decode(GuestSetupInfo.self, from: Data(json.utf8))
		#expect(back.notes == info.notes)
	}

	@Test func noNotesNoKey() throws {
		let json = String(
			decoding: try MachmanWire.encoder().encode(GuestSetupInfo()), as: UTF8.self)
		#expect(json == "{}")
		let older = try MachmanWire.decoder().decode(
			GuestSetupInfo.self, from: Data(#"{"installed":true,"errors":[]}"#.utf8))
		#expect(older.notes == nil)
	}
}
