//
//  CopyMountIDsWireTests.swift
//  MachmanTests
//
//  vm.copy's mountIDs (C11) is an additive request key: sent only when a client chose
//  mounts, absent from every older client's request (which still decodes, as "all").
//  Kept apart from WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct CopyMountIDsWireTests {
	@Test func chosenMountsRideTheRequest() throws {
		let params = RPCParams.Copy(
			name: "Debian", newName: "Deb2", diskIDs: ["storage:disk"], regenerateMAC: nil,
			mountIDs: ["7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"])
		let json = String(decoding: try MachmanWire.encoder().encode(params), as: UTF8.self)
		#expect(json == #"{"diskIDs":["storage:disk"],"#
			+ #""mountIDs":["7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"],"#
			+ #""name":"Debian","newName":"Deb2"}"#)
		let decoded = try MachmanWire.decoder().decode(RPCParams.Copy.self, from: Data(json.utf8))
		#expect(decoded == params)
	}

	@Test func anOlderClientsRequestCarriesEveryMount() throws {
		let legacy = #"{"diskIDs":["storage:disk"],"name":"Debian","regenerateMAC":true}"#
		let decoded = try MachmanWire.decoder()
			.decode(RPCParams.Copy.self, from: Data(legacy.utf8))
		#expect(decoded.mountIDs == nil)
		let json = String(
			decoding: try MachmanWire.encoder().encode(decoded), as: UTF8.self)
		#expect(!json.contains("mountIDs"))
	}
}
