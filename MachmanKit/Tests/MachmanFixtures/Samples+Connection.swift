//
//  Samples+Connection.swift
//  MachmanFixtures
//
//  Operations in their terminal states, as host.operations still lists them for a while
//  after they end (and a resyncing client receives them). Labels follow LocalMachman's:
//  "Importing <file>" on the VM, "Copying <source> → <target>" on the copy.
//

import Foundation
import MachmanAPI

extension Samples {
	// A disk import that finished while the client was away.
	public static func finishedImport(vm: String = "Fedora", file: String = "data.img")
		-> OperationInfo {
		OperationInfo(
			id: "op-import-done", kind: OperationInfo.Kind.importDisk, vm: vm,
			label: "Importing \(file)", fraction: 1,
			completedBytes: 8 << 30, totalBytes: 8 << 30,
			startedAt: now.addingTimeInterval(-40), state: OperationInfo.State.succeeded)
	}

	// A duplicate of `source` the user cancelled part-way.
	public static func cancelledCopy(of source: String = "Alpine") -> OperationInfo {
		OperationInfo(
			id: "op-copy-cancelled", kind: OperationInfo.Kind.copyVM, vm: "\(source) copy",
			label: "Copying \(source) → \(source) copy", fraction: 0.3,
			startedAt: now.addingTimeInterval(-20), state: OperationInfo.State.cancelled)
	}
}
