//
//  FakeDaemonTests.swift
//  MachmanDesktopCoreTests
//
//  The fake agent's own proof, against the real client (RemoteMachman over a real socket):
//  scripted hello versions, a stalled hello timing out, a drop mid-call recorded as an
//  interrupted call, an event reaching the stream, scripts taken per connection, and a
//  stopped listener reading as an agent that isn't running.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: a scripted fake agent socket in the run's scratch space (no real agent).
struct FakeDaemonTests {
	@Test("Q18: the fake daemon answers hello with the scripted versions")
	func answersHello() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .agent(version: "1.2.3")
		let remote = try await daemon.remote()
		#expect(remote.hello.daemonVersion == "1.2.3")
		#expect(remote.hello.apiVersion == MachmanProtocol.apiVersion)
		let hello = try #require(daemon.requests.first)
		#expect(hello.connection == 1)
		#expect(hello.method == RPCMethod.hello.rawValue)
		#expect(hello.params == #"{"client":"MachmanDesktopCoreTests"}"#)
		await remote.disconnect()
	}

	@Test("Q18: a stalled hello times out the client with the timeout code")
	func stalledHelloTimesOut() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .silent
		await #expect {
			_ = try await daemon.remote(helloDeadline: .seconds(2))
		} throws: { error in
			(error as? MachmanError)?.code == .timeout
		}
		#expect(daemon.requests.map(\.method) == [RPCMethod.hello.rawValue])
	}

	@Test("Q18: a drop mid-call fails the call and records it as interrupted")
	func dropMidCallIsInterrupted() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .agent([.start: .drop])
		let dropped = DropFlag()
		let remote = try await daemon.remote(onDrop: { dropped.set() })
		await #expect(throws: RPCConnection.ConnectionError.self) {
			try await remote.start(vm: "Debian", options: StartOptions())
		}
		#expect(await remote.interruptedCalls() == [InterruptedCall(method: .start, vm: "Debian")])
		#expect(await eventually { dropped.isSet })
	}

	@Test("Q18: an event reaches the client's event stream")
	func eventReachesTheStream() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .agent()
		let remote = try await daemon.remote()
		let stream = await remote.events()
		#expect(await daemon.waitForRequest(RPCMethod.eventsSubscribe.rawValue))
		daemon.send(.stateChanged(vm: "Debian", state: .running))
		let first = await FirstEvent.of(stream, within: .seconds(10))
		#expect(first == .event(.stateChanged(vm: "Debian", state: .running)))
		await remote.disconnect()
	}

	// RPCConnection.events() adds a subscriber whether or not the connection already died, and
	// only a live teardown finishes subscribers: a store that subscribes just after a drop
	// waits on its stream forever (the loop reconnects with new stores; the old task leaks).
	@Test("Q18: an event stream opened after the connection dropped ends at once")
	func streamOpenedAfterADropEnds() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.otherwise = .agent()
		let dropped = DropFlag()
		let remote = try await daemon.remote(onDrop: { dropped.set() })
		daemon.dropAll()
		#expect(await eventually { dropped.isSet })
		let stream = await remote.events()
		let first = await FirstEvent.of(stream, within: .seconds(2))
		withKnownIssue(Comment(rawValue: "E49: An event stream opened on a dropped connection "
			+ "never ends: RPCConnection registers it after teardown already ran")) {
			#expect(first == .ended)
		}
	}

	@Test("Q18: each connection takes the next script, and a stopped listener reads as not running")
	func scriptsPerConnectionAndStoppedListener() async throws {
		let daemon = try FakeDaemon()
		defer { daemon.close() }
		daemon.scripts = [.agent(version: "1.0.1"), .agent(version: "1.0.2")]
		daemon.otherwise = .agent(version: "1.0.3")
		var versions: [String] = []
		for _ in 1...3 {
			let remote = try await daemon.remote()
			versions.append(remote.hello.daemonVersion)
			await remote.disconnect()
		}
		#expect(versions == ["1.0.1", "1.0.2", "1.0.3"])
		#expect(daemon.connectionCount == 3)
		#expect(daemon.requests.map(\.connection) == [1, 2, 3])

		daemon.stopListening()
		do {
			_ = try await daemon.remote()
			Issue.record("a stopped listener accepted a connection")
		} catch {
			let problem = ConnectionProblem.classify(error)
			#expect(problem.kind == .unreachable)
			#expect(problem.detail == "It isn\u{2019}t running.")
		}
	}
}
