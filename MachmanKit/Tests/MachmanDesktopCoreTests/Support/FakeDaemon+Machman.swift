//
//  FakeDaemon+Machman.swift
//  MachmanDesktopCoreTests
//
//  The typed half of the fake agent (MachmanTestSupport's FakeDaemon is Foundation only): an
//  agent script that answers machman.hello with chosen versions and accepts the events
//  subscription, a silent one whose hello never answers, wire-encoded results and events,
//  and the real client connected to it.
//

import Foundation
import MachmanAPI
import MachmanClient
import MachmanTestSupport

extension FakeDaemon.Script {
	// An agent: hello with these versions, events.subscribe accepted, `replies` on top;
	// anything else is a method it doesn't know.
	static func agent(
		version: String = "1.0.12", apiVersion: Int = MachmanProtocol.apiVersion,
		_ replies: [RPCMethod: FakeDaemon.Reply] = [:]
	) -> Self {
		var all: [String: FakeDaemon.Reply] = [
			RPCMethod.hello.rawValue: .json(
				RPCResults.Hello(apiVersion: apiVersion, daemonVersion: version)),
			RPCMethod.eventsSubscribe.rawValue: .result("{}"),
		]
		for (method, reply) in replies {
			all[method.rawValue] = reply
		}
		return Self(replies: all)
	}

	// Accepts the connection, never answers the hello (a hung agent).
	static let silent = Self(replies: [RPCMethod.hello.rawValue: .stall])
}

extension FakeDaemon.Reply {
	static func json(_ value: some Encodable) -> Self {
		.result(String(decoding: try! MachmanWire.encoder().encode(value), as: UTF8.self))
	}
}

extension FakeDaemon {
	// An event's params, as the agent's notification carries them.
	static func eventParams(_ event: VMEvent) -> String {
		String(decoding: try! MachmanWire.encoder().encode(event), as: UTF8.self)
	}

	func send(_ event: VMEvent) {
		notify(RPCMethod.event.rawValue, paramsJSON: Self.eventParams(event))
	}

	// The real client, connected to this fake (never the default socket path).
	func remote(
		helloDeadline: Duration = .seconds(10), onDrop: @escaping @Sendable () -> Void = {}
	) async throws -> RemoteMachman {
		try await RemoteMachman(
			socketPath: socketPath, clientName: "MachmanDesktopCoreTests",
			helloDeadline: helloDeadline, onDisconnect: onDrop)
	}
}

// Set from any thread (a connection's drop callback), read anywhere.
final class DropFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false

	var isSet: Bool { lock.withLock { value } }

	func set() { lock.withLock { value = true } }
}

// What a stream yields first, bounded: a stream that never yields fails a test at the
// deadline instead of hanging the run.
enum FirstEvent: Equatable {
	case event(VMEvent)
	case ended
	case timedOut

	static func of(_ stream: AsyncStream<VMEvent>, within deadline: Duration) async -> Self {
		await withTaskGroup(of: FirstEvent.self) { group in
			group.addTask {
				var events = stream.makeAsyncIterator()
				return await events.next().map(FirstEvent.event) ?? .ended
			}
			group.addTask {
				try? await Task.sleep(for: deadline)
				return .timedOut
			}
			let first = await group.next() ?? .timedOut
			group.cancelAll()
			return first
		}
	}
}
