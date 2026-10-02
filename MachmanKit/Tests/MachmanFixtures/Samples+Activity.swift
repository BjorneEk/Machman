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

extension Samples {
	// A running copy whose name is longer than the toolbar indicator's 220 pt: copies are
	// named "<name> copy N", so the end is what tells them apart (L5).
	public static func longNamedLinux() -> VMInfo {
		linux("Debian 13 trixie arm64 build server copy 2", state: .running)
	}

	// A guest whose soft shutdown is under way (F3).
	public static func stoppingLinux(_ name: String = "Debian") -> VMInfo {
		linux(name, state: .stopping)
	}
}

extension Samples {
	// A disk import that failed part-way, with the copier's error as its message (L4).
	public static func failedImport(
		vm: String = "Debian", file: String = "big-archive-disk-image-2026.raw"
	) -> OperationInfo {
		OperationInfo(
			id: "op-import-failed", kind: OperationInfo.Kind.importDisk, vm: vm,
			label: "Importing \(file)", fraction: 0.62,
			completedBytes: 40 << 30, totalBytes: 64 << 30,
			startedAt: now.addingTimeInterval(-300), state: OperationInfo.State.failed,
			message: "The file \u{201C}\(file)\u{201D} couldn\u{2019}t be copied because there "
				+ "isn\u{2019}t enough space on the volume.",
			cancellable: true)
	}
}
