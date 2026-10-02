//
//  VMTemplateWireTests.swift
//  MachmanTests
//
//  A8: VMTemplate's raw values are vm.create's wire spellings, so they are pinned: renaming
//  a case would silently change what clients send. Kept apart from WireFixtureTests, whose
//  pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct VMTemplateWireTests {
	@Test func theTemplateNamesAreTheWireSpellings() {
		#expect(VMTemplate.allCases.map(\.rawValue) == ["blank", "default", "mac"])
	}

	@Test func aTemplateGoesOutAsItsName() throws {
		let data = try MachmanWire.encoder().encode(
			RPCParams.Create(template: VMTemplate.mac.rawValue))
		#expect(String(decoding: data, as: UTF8.self) == #"{"template":"mac"}"#)
	}
}
