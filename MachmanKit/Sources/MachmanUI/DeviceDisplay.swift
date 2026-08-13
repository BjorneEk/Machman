//
//  DeviceDisplay.swift
//  MachmanUI
//
//  The shared display vocabulary for guest device kinds (1.0.4 UI): one symbol + label per
//  kind, used by the sidebar tree, the add popover, and the device inspectors, so the
//  mapping never forks. Configurable kinds get inspectors and are selectable in the tree;
//  the rest are dim rows with a Remove action.
//

import MachmanAPI

extension DeviceKind {
	public var displaySymbol: String {
		switch self {
		case .graphics: return MachmanSymbols.deviceGraphics
		case .keyboard: return MachmanSymbols.deviceKeyboard
		case .trackpad: return MachmanSymbols.deviceTrackpad
		case .pointer: return MachmanSymbols.devicePointer
		case .audioInput: return MachmanSymbols.deviceAudioIn
		case .audioOutput: return MachmanSymbols.deviceAudioOut
		case .network: return MachmanSymbols.network
		case .clipboard: return MachmanSymbols.deviceClipboard
		case .entropy: return MachmanSymbols.deviceEntropy
		case .rosetta: return MachmanSymbols.deviceRosetta
		case .unknown: return MachmanSymbols.warning
		}
	}

	public var displayLabel: String {
		switch self {
		case .graphics: return "Display"
		case .keyboard: return "Keyboard"
		case .trackpad: return "Trackpad"
		case .pointer: return "Pointer"
		case .audioInput: return "Mic"
		case .audioOutput: return "Audio"
		case .network: return "Network"
		case .clipboard: return "Clipboard"
		case .entropy: return "Entropy"
		case .rosetta: return "Rosetta"
		case .unknown: return "Unknown"
		}
	}

	// Kinds with settings behind them (an inspector): selectable in the device tree.
	public var isConfigurable: Bool {
		switch self {
		case .graphics, .network, .clipboard, .rosetta: return true
		default: return false
		}
	}
}
