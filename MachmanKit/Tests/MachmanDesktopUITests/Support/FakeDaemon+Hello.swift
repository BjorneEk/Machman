//
//  FakeDaemon+Hello.swift
//  MachmanDesktopUITests
//
//  The fake agent's hello scripts and client for this target: a copy of DesktopCoreTests'
//  FakeDaemon+Machman.swift (the parts the connect-screen tests use), because
//  MachmanTestSupport's FakeDaemon stays Foundation only (r3-ta T7) and test targets can't
//  share support files.
//

import Foundation
import MachmanAPI
import MachmanClient
import MachmanTestSupport

extension FakeDaemon.Script {
	static func agent(version: String = "1.0.12") -> Self {
		let hello = RPCResults.Hello(apiVersion: MachmanProtocol.apiVersion, daemonVersion: version)
		return Self(replies: [
			RPCMethod.hello.rawValue: .result(
				String(decoding: try! MachmanWire.encoder().encode(hello), as: UTF8.self)),
			RPCMethod.eventsSubscribe.rawValue: .result("{}"),
		])
	}

	// Accepts the connection, never answers the hello (a hung agent).
	static let silent = Self(replies: [RPCMethod.hello.rawValue: .stall])
}

extension FakeDaemon {
	func remote(
		helloDeadline: Duration = .seconds(10), onDrop: @escaping @Sendable () -> Void = {}
	) async throws -> RemoteMachman {
		try await RemoteMachman(
			socketPath: socketPath, clientName: "MachmanDesktopUITests",
			helloDeadline: helloDeadline, onDisconnect: onDrop)
	}
}
