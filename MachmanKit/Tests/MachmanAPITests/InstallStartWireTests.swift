//
//  InstallStartWireTests.swift
//  MachmanAPITests
//
//  D32: vm.install.start's optional diskID names the disk the switch sheet's user picked for
//  macOS. Absent, the request is byte-identical to the one every older client sends — and an
//  older daemon reading a request with it simply ignores the key. Kept apart from
//  WireFixtureTests, whose pinned fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanAPI

struct InstallStartWireTests {
	private func encode<T: Encodable>(_ value: T) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(value), as: UTF8.self)
	}

	@Test("D32: vm.install.start carries diskID only when a disk is picked")
	func theDiskGoesOutOnlyWhenPicked() throws {
		#expect(try encode(RPCParams.InstallStart(name: "Debian", source: .latest))
			== #"{"name":"Debian","source":{"kind":"latest"}}"#)
		#expect(try encode(RPCParams.InstallStart(
			name: "Debian", source: .latest, diskID: "storage:system"))
			== #"{"diskID":"storage:system","name":"Debian","source":{"kind":"latest"}}"#)
		let older = try MachmanWire.decoder().decode(
			RPCParams.InstallStart.self,
			from: Data(#"{"name":"Debian","source":{"kind":"ipsw","path":"/a.ipsw"}}"#.utf8))
		#expect(older == RPCParams.InstallStart(name: "Debian", source: .ipsw("/a.ipsw")))
	}
}
