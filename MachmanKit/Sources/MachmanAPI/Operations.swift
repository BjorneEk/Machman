//
//  Operations.swift
//  MachmanAPI
//
//  Generic long-running-operation reporting (wire 1.0.4). Copies, disk imports/promotes,
//  kernel imports, shadow builds and Rosetta installs register an OperationInfo; every
//  change is broadcast as VMEvent.operationChanged, and host.operations returns the live
//  list so clients resync after a reconnect (events have no replay). The macOS install
//  keeps its richer installPhaseChanged flow. ETA is consumer math (bytes + startedAt),
//  same rule as copyProgress.
//

import Foundation

public struct OperationInfo: Codable, Sendable, Equatable, Identifiable {
	// Operation kinds are an open set of strings on the wire; these are the ones the
	// daemon emits today. Unknown kinds must render generically, never fail.
	public enum Kind {
		public static let copyVM = "copyVM"
		public static let importDisk = "importDisk"
		public static let promoteDisk = "promoteDisk"
		public static let shadowBuild = "shadowBuild"
		public static let safeSave = "safeSave"
		public static let kernelImport = "kernelImport"
		public static let rosettaInstall = "rosettaInstall"
	}

	public enum State {
		public static let running = "running"
		public static let succeeded = "succeeded"
		public static let failed = "failed"
		public static let cancelled = "cancelled"
	}

	public var id: String                 // "op-…", unique per operation
	public var kind: String               // OperationInfo.Kind.* (open set)
	public var vm: String?                // the VM it concerns, when there is one
	public var label: String              // human phase text ("Copying system.img…")
	public var fraction: Double?          // 0…1; nil = indeterminate
	public var completedBytes: Int64?
	public var totalBytes: Int64?
	public var startedAt: Date
	public var state: String              // OperationInfo.State.* (open set)
	public var message: String?           // failure/cancel detail

	public init(
		id: String, kind: String, vm: String? = nil, label: String,
		fraction: Double? = nil, completedBytes: Int64? = nil, totalBytes: Int64? = nil,
		startedAt: Date, state: String = State.running, message: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.vm = vm
		self.label = label
		self.fraction = fraction
		self.completedBytes = completedBytes
		self.totalBytes = totalBytes
		self.startedAt = startedAt
		self.state = state
		self.message = message
	}

	public var isFinished: Bool { state != State.running }
}
