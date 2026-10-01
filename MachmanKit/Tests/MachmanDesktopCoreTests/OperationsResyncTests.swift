//
//  OperationsResyncTests.swift
//  MachmanDesktopCoreTests
//
//  P24: host.operations lists finished operations for a while, and a reconnect inside that
//  window resynced them — but pruning was scheduled only from terminal events, so their Done
//  or Failed cards never left. Now a resynced finished card ages out like any other, and a
//  pruned one stays gone though the daemon still lists it.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct OperationsResyncTests {

	@Test func aResyncedFinishedOperationLeaves() async {
		let stub = StubMachman.serving(Samples.library())
		stub.ops = [Samples.finishedImport()]
		let operations = OperationsStore(linger: .milliseconds(100))
		operations.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) {
			operations.operations.map(\.id) == ["op-import-done"]
		})
		#expect(await eventually(timeout: .seconds(5)) { operations.operations.isEmpty })
		operations.detach()
	}

	@Test func aPrunedOperationDoesNotReturnOnResync() async {
		let stub = StubMachman.serving(Samples.library())
		stub.ops = [Samples.finishedImport()]
		let operations = OperationsStore(linger: .milliseconds(100))
		operations.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) {
			operations.operations.map(\.id) == ["op-import-done"]
		})
		#expect(await eventually(timeout: .seconds(5)) { operations.operations.isEmpty })
		// A reconnect while the daemon still lists it.
		let resyncs = stub.calls.filter { $0 == "operations" }.count
		operations.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) {
			stub.calls.filter { $0 == "operations" }.count > resyncs
		})
		try? await Task.sleep(for: .milliseconds(300))
		#expect(operations.operations.isEmpty)
		operations.detach()
	}

	@Test func aRunningOperationStays() async {
		let stub = StubMachman.serving(Samples.library())
		stub.ops = [Samples.copyOperation(), Samples.finishedImport()]
		let operations = OperationsStore(linger: .milliseconds(100))
		operations.attach(api: stub)
		#expect(await eventually(timeout: .seconds(5)) { operations.operations.count == 2 })
		#expect(await eventually(timeout: .seconds(5)) {
			operations.operations.map(\.id) == ["op-1"]
		})
		try? await Task.sleep(for: .milliseconds(300))
		#expect(operations.operations.map(\.id) == ["op-1"])
		operations.detach()
	}
}
