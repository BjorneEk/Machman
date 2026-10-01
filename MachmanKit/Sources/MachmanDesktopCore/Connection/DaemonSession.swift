//
//  DaemonSession.swift
//  MachmanDesktopCore
//
//  One live connection to the agent, as the connect loop sees it: the api the stores and
//  view model use, the version the hello reported, the events subscription that must hold
//  before the session counts, a way to drop it, and — once dropped — what the drop cut off.
//  RemoteMachman is the real one; the loop's tests drive fakes.
//

import Foundation
import MachmanAPI
import MachmanClient

@MainActor
public protocol DaemonSession: AnyObject {
	var api: MachmanControlling { get }
	var daemonVersion: String { get }
	func subscribeEvents() async throws
	func disconnect() async
	func interruptedCalls() async -> [InterruptedCall]
}

extension RemoteMachman: DaemonSession {
	public var api: MachmanControlling { self }
	public var daemonVersion: String { hello.daemonVersion }
}
