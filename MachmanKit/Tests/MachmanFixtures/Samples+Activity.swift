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
