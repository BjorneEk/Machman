//
//  InterruptedCall.swift
//  MachmanClient
//
//  A request that was on the wire with no reply when its connection died. It may or may not
//  have run: the peer can have finished it, be finishing it, or never have read it — so a
//  client that cares re-reads state rather than assuming either outcome.
//

import Foundation
import MachmanAPI

public struct InterruptedCall: Sendable, Equatable {
	public let method: RPCMethod
	public let vm: String?   // the request's params.name, when it had one

	public init(method: RPCMethod, vm: String?) {
		self.method = method
		self.vm = vm
	}
}
