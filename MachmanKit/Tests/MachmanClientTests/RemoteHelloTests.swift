//
//  RemoteHelloTests.swift
//  MachmanClientTests
//
//  P1's root: a hello that never completed must not report a disconnect. The caller's catch
//  already has that failure; a drop report on top made the desktop restart its connect loop
//  (fresh counter, another agent launch) on every refused or silent hello, forever. A
//  connection RemoteMachman.init DID hand out still reports its drop, exactly once.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanClient

struct RemoteHelloTests {

	@Test func aRefusedHelloReportsNoDisconnect() async throws {
		let peer = try ScriptedPeer(helloAPIVersion: 999)
		defer { peer.close() }
		let drops = DropCounter()
		do {
			_ = try await RemoteMachman(
				socketPath: peer.socketPath, clientName: "hello-refused",
				helloDeadline: .seconds(10), onDisconnect: { drops.increment() })
			Issue.record("expected the api mismatch to refuse the connection")
		} catch let error as RemoteMachman.APIVersionMismatch {
			#expect(error == RemoteMachman.APIVersionMismatch(
				daemonAPI: 999, clientAPI: MachmanProtocol.apiVersion))
			// The log keeps the text it had before the type existed.
			#expect("\(error)"
				== "daemon speaks api v999, client needs v\(MachmanProtocol.apiVersion)")
			// A person reads a sentence (a failed start's reason relays it).
			#expect(MachmanError.userMessage(for: error)
				== "It speaks API version 999 instead of \(MachmanProtocol.apiVersion)")
		}
		try await Task.sleep(for: .milliseconds(300))
		#expect(drops.count == 0)
	}

	@Test func aSilentHelloReportsNoDisconnect() async throws {
		let peer = try ScriptedPeer(helloAPIVersion: nil)
		defer { peer.close() }
		let drops = DropCounter()
		do {
			_ = try await RemoteMachman(
				socketPath: peer.socketPath, clientName: "hello-silent",
				helloDeadline: .milliseconds(300), onDisconnect: { drops.increment() })
			Issue.record("expected the hello to time out")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
		}
		try await Task.sleep(for: .milliseconds(300))
		#expect(drops.count == 0)
	}

	@Test func aCancelledHelloReportsNoDisconnect() async throws {
		let peer = try ScriptedPeer(helloAPIVersion: nil)
		defer { peer.close() }
		let drops = DropCounter()
		let attempt = Task {
			_ = try await RemoteMachman(
				socketPath: peer.socketPath, clientName: "hello-cancelled",
				helloDeadline: .seconds(30), onDisconnect: { drops.increment() })
		}
		await peer.waitForRequests(1)
		attempt.cancel()
		guard case .failure(let error) = await attempt.result else {
			Issue.record("expected the cancelled hello to fail")
			return
		}
		#expect(error is CancellationError)
		try await Task.sleep(for: .milliseconds(300))
		#expect(drops.count == 0)
	}

	// The arm path: a connection init handed out reports its drop, once, and a later
	// disconnect() of the dead connection adds nothing.
	@Test func aLiveConnectionReportsItsDropOnce() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let drops = DropCounter()
		let client = try await RemoteMachman(
			socketPath: peer.socketPath, clientName: "hello-live",
			helloDeadline: .seconds(10), onDisconnect: { drops.increment() })
		#expect(client.hello.apiVersion == MachmanProtocol.apiVersion)
		#expect(drops.count == 0)
		peer.dropConnection()
		#expect(await eventually(timeout: .seconds(5)) { drops.count == 1 })
		try await Task.sleep(for: .milliseconds(300))
		await client.disconnect()
		#expect(drops.count == 1)
	}
}

final class DropCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	func increment() { lock.withLock { value += 1 } }
	var count: Int { lock.withLock { value } }
}
