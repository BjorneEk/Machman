//
//  InterruptedCallsTests.swift
//  MachmanClientTests
//
//  P12's record: when a connection dies, the requests still waiting for a reply are what
//  the drop cut off — the only place that knows is the connection itself. Answered calls are
//  not on the list, and a live connection lists nothing.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanClient

struct InterruptedCallsTests {

	@Test func aDropListsTheCallsLeftUnanswered() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let connection = try RPCConnection(socketPath: peer.socketPath)
		let delete = Task {
			try await connection.call(
				.vmDelete, RPCParams.Name(name: "Debian"), expecting: RPCEmpty.self,
				deadline: .seconds(30))
		}
		await peer.waitForRequests(1)
		let list = Task {
			try await connection.call(
				.vmList, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(30))
		}
		await peer.waitForRequests(2)
		peer.dropConnection()
		await #expect(throws: RPCConnection.ConnectionError.self) { try await delete.value }
		await #expect(throws: RPCConnection.ConnectionError.self) { try await list.value }
		#expect(await connection.interruptedCalls() == [
			InterruptedCall(method: .vmDelete, vm: "Debian"),
			InterruptedCall(method: .vmList, vm: nil),
		])
	}

	@Test func anAnsweredCallIsNotListed() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let connection = try RPCConnection(socketPath: peer.socketPath)
		let stop = Task {
			try await connection.call(
				.stop, RPCParams.Name(name: "Alpine"), expecting: RPCEmpty.self,
				deadline: .seconds(30))
		}
		await peer.waitForRequests(1)
		peer.reply(id: peer.seen[0].id)
		_ = try await stop.value
		let start = Task {
			try await connection.call(
				.start, RPCParams.Name(name: "Debian"), expecting: RPCEmpty.self,
				deadline: .seconds(30))
		}
		await peer.waitForRequests(2)
		peer.dropConnection()
		_ = await start.result
		#expect(await connection.interruptedCalls() == [
			InterruptedCall(method: .start, vm: "Debian"),
		])
	}

	@Test func aLiveConnectionListsNothing() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let client = try await RemoteMachman(
			socketPath: peer.socketPath, clientName: "interrupted-live",
			helloDeadline: .seconds(10))
		#expect(await client.interruptedCalls().isEmpty)
		await client.disconnect()
		// A drop with nothing in flight cut nothing off.
		#expect(await client.interruptedCalls().isEmpty)
	}
}
