//
//  OperationInfo+Display.swift
//  MachmanDesktopCore
//
//  How an operation reads to a person, wherever it shows: the corner's progress card and
//  the activity list share its title, symbol and outcome.
//

import Foundation
import MachmanAPI
import MachmanUI

extension OperationInfo {
	// The card's and the list's title: the VM it concerns, then what it does.
	public var displayTitle: String {
		vm.map { "\($0) — \(label)" } ?? label
	}

	public var displaySymbol: String {
		switch kind {
		case Kind.copyVM: return MachmanSymbols.duplicateVM
		case Kind.importDisk, Kind.promoteDisk: return MachmanSymbols.diskStorage
		case Kind.shadowBuild, Kind.safeSave: return MachmanSymbols.safe
		case Kind.kernelImport: return MachmanSymbols.initramfs
		case Kind.rosettaInstall: return MachmanSymbols.deviceRosetta
		default: return MachmanSymbols.more
		}
	}

	// How it ended; nil while it runs (or in a state this build doesn't know).
	public var outcomeText: String? {
		switch state {
		case State.succeeded: return "Done"
		case State.failed: return message ?? "Failed"
		case State.cancelled: return "Canceled"
		default: return nil
		}
	}
}
