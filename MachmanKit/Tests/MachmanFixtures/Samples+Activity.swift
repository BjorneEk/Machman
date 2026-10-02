//
//  Samples+Activity.swift
//  MachmanFixtures
//
//  Wave 3, lane 3d: operations, VMs and engine warnings for the corner overlay, the toolbar
//  and the activity list. Labels follow the engine's own (LocalMachman, RoutingMachman).
//

import Foundation
import MachmanAPI

extension Samples {
	// A Rosetta install in flight: RoutingMachman registers it without a cancel hook, so the
	// engine says it can't be cancelled (F7).
	public static func rosettaInstallOperation() -> OperationInfo {
		OperationInfo(
			id: "op-rosetta", kind: OperationInfo.Kind.rosettaInstall,
			label: "Installing Rosetta", startedAt: now.addingTimeInterval(-15),
			cancellable: false)
	}
}

extension Samples {
	// A copy of `source` in flight, labelled as LocalMachman.copyLabel labels it: the card's
	// title names the copy, the label only the source (F8).
	public static func copyFromOperation(source: String = "Alpine") -> OperationInfo {
		OperationInfo(
			id: "op-copy-from", kind: OperationInfo.Kind.copyVM, vm: "\(source) copy",
			label: "Copying from \(source)", fraction: 0.3,
			completedBytes: 6 << 30, totalBytes: 20 << 30,
			startedAt: now.addingTimeInterval(-30), cancellable: true)
	}
}
