//
//  SerialPortRef.swift
//  MachmanUI
//
//  A stable, logical identity for one serial port: its family + index. Unlike SerialPortInfo's
//  socketPath (which exists only while the VM runs and is a hashed temp path), a ref is derived
//  purely from configuration, so it survives VM stops/restarts and is the natural key for terminal
//  tabs and per-socket profile associations.
//

import Foundation
import MachmanAPI

public struct SerialPortRef: Hashable, Codable, Sendable {
	public var kind: SerialPortKind
	public var index: Int

	public init(kind: SerialPortKind, index: Int) {
		self.kind = kind
		self.index = index
	}

	public init(_ port: SerialPortInfo) {
		self.kind = port.kind
		self.index = port.index
	}

	// The guest device name (hvc0 / ttyAMA0 / cu.virtio0) for display.
	public func guestDevice(macGuest: Bool) -> String {
		kind.guestDevice(index: index, macGuest: macGuest)
	}

	// Key for per-socket profile associations: stable across runs, unique within a VM.
	public func assocKey(vm: String) -> String {
		"\(vm)|\(kind.rawValue)|\(index)"
	}
}
