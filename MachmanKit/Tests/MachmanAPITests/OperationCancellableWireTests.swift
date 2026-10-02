//
//  OperationCancellableWireTests.swift
//  MachmanAPITests
//
//  OperationInfo.cancellable (F7, 1.0.12+) is an additive key: sent by a daemon that knows
//  whether op.cancel would refuse, absent from every older daemon's payload (which a client
//  reads as cancellable, today's behaviour). Kept apart from WireFixtureTests, whose pinned
//  fixtures must stay byte-identical.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct OperationCancellableWireTests {
	private func encode(_ op: OperationInfo) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(op), as: UTF8.self)
	}

	private func decode(_ json: String) throws -> OperationInfo {
		try MachmanWire.decoder().decode(OperationInfo.self, from: Data(json.utf8))
	}

	@Test func anOperationThatCantCancelSaysSo() throws {
		let op = OperationInfo(
			id: "op-2", kind: OperationInfo.Kind.rosettaInstall, label: "Installing Rosetta",
			startedAt: Date(timeIntervalSince1970: 1_700_000_000), cancellable: false)
		let json = try encode(op)
		#expect(json == #"{"cancellable":false,"id":"op-2","kind":"rosettaInstall","#
			+ #""label":"Installing Rosetta","startedAt":"2023-11-14T22:13:20Z","#
			+ #""state":"running"}"#)
		let decoded = try decode(json)
		#expect(decoded == op)
		#expect(!decoded.isCancellable)
	}

	@Test func anUnknownAnswerIsLeftOut() throws {
		let op = OperationInfo(
			id: "op-2", kind: OperationInfo.Kind.rosettaInstall, label: "Installing Rosetta",
			startedAt: Date(timeIntervalSince1970: 1_700_000_000))
		#expect(try !encode(op).contains("cancellable"))
	}

	@Test func anOlderDaemonsOperationReadsAsCancellable() throws {
		let legacy = try decode(#"{"id":"op-1","kind":"copyVM","label":"Copying","#
			+ #""startedAt":"2023-11-14T22:13:20Z","state":"running"}"#)
		#expect(legacy.cancellable == nil)
		#expect(legacy.isCancellable)
	}
}
