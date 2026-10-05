//
//  RPCReplyDecodeTests.swift
//  MachmanClientTests
//
//  Q5: every reply was parsed three times (the routing peek, an attempt at the error
//  envelope, the result) and every event twice. The routing read now carries what each line
//  needs — an error reply's error, an event's payload — and only a result is read again, as
//  the caller's own type.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient

struct RPCReplyDecodeTests {
	// No "jsonrpc": the full error envelope never decoded from such a line, so the caller got
	// a DecodingError. The error read with the routing is enough now.
	@Test func anErrorReplyIsReadWithItsRouting() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let connection = try RPCConnection(socketPath: peer.socketPath)
		let get = Task {
			try await connection.call(
				.vmGet, RPCParams.Name(name: "Debian"), expecting: RPCEmpty.self,
				deadline: .seconds(30))
		}
		await peer.waitForRequests(1)
		let id = try #require(peer.seen.first?.id)
		peer.sendLine(#"{"id":\#(id),"error":{"code":-32000,"message":"Debian is starting","#
			+ #""data":{"machmanCode":"invalidState"}}}"#)
		do {
			_ = try await get.value
			Issue.record("expected the call to fail")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "Debian is starting")
		}
	}

	// An event and a reply written back to back: the event reaches the subscriber, the
	// reply its caller.
	@Test func anEventAndAReplyBothLand() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let connection = try RPCConnection(socketPath: peer.socketPath)
		let events = await connection.events()
		let list = Task {
			try await connection.call(
				.vmList, RPCEmpty?.none, expecting: [String].self, deadline: .seconds(30))
		}
		await peer.waitForRequests(1)
		let id = try #require(peer.seen.first?.id)
		peer.sendLine(#"{"jsonrpc":"2.0","method":"event","params":{"type":"listChanged"}}"#)
		peer.reply(id: id, resultJSON: #"["Debian"]"#)
		#expect(try await list.value == ["Debian"])
		var iterator = events.makeAsyncIterator()
		#expect(await iterator.next() == .listChanged)
	}
}
