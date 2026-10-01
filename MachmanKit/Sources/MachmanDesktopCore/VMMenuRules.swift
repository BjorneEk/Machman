//
//  VMMenuRules.swift
//  MachmanDesktopCore
//
//  Which actions a VM offers, decided once for every surface that offers them (the tree's
//  menus, the picker, the inspectors, the menu bar). Stop-first actions (P14) mirror the
//  daemon's RoutingMachman.requireStopped callers: a new requireStopped call adds a case
//  here. While the VM runs they show DISABLED with the reason, never hidden — so the menu
//  doesn't change shape under the user and the reason is there to read.
//

import Foundation
import MachmanAPI

public enum StoppedOnly: CaseIterable, Sendable {
	case deleteVM
	case renameVM
	case duplicateVM
	case regenerateMAC
	case removeDisk
	case promoteDisk
	case resizeDisk
	case renameDisk
	case changeSerialPorts
	case renameKernelFile
	case installMacOS

	// One short sentence, the inspectors' existing wording.
	public var stopFirst: String {
		switch self {
		case .deleteVM: return "Stop the VM to delete it"
		case .renameVM: return "Stop the VM to rename it"
		case .duplicateVM: return "Stop the VM to duplicate it"
		case .regenerateMAC: return "Stop the VM to change its MAC address"
		case .removeDisk: return "Stop the VM to remove its disks"
		case .promoteDisk: return "Stop the VM to promote its disks"
		case .resizeDisk: return "Stop the VM to grow its disks"
		case .renameDisk: return "Stop the VM to rename its disks"
		case .changeSerialPorts: return "Stop the VM to add or remove serial ports"
		case .renameKernelFile: return "Stop the VM to rename its kernel files"
		case .installMacOS: return "Stop the VM to install macOS"
		}
	}
}

extension VMInfo {
	// Why the daemon would refuse the action now, or nil when it is offered. A starting,
	// stopping or paused VM is hosted too, and one whose vmhost stopped answering may still
	// be (the daemon refuses while it can't tell).
	public func refusal(_ action: StoppedOnly) -> String? {
		state.isRunning || isUnresponsive ? action.stopFirst : nil
	}
}
