//
//  DeviceDisplay.swift
//  MachmanUI
//
//  The shared display vocabulary for guest device kinds (1.0.4 UI): one symbol + label per
//  kind, plus the VZ class/variant the engine resolves it to, used by the sidebar tree, the
//  add popover, and the device inspectors, so the mapping never forks. Every real kind is
//  selectable in the tree; kinds without settings get the generic info inspector.
//

import MachmanAPI

extension DeviceKind {
	// Installer devices — share-served setup payloads (Console Login, SSH Setup). They
	// get their own tree/popover section: they configure the guest, they're not hardware.
	// The ONE taxonomy spot a future installer kind must join.
	public var isInstaller: Bool {
		switch self {
		case .consoleLoginInstaller, .sshInstaller: return true
		default: return false
		}
	}

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
		case .consoleLoginInstaller: return MachmanSymbols.deviceLoginInstaller
		case .sshInstaller: return MachmanSymbols.deviceSSHSetup
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
		case .consoleLoginInstaller: return "Console Login"
		case .sshInstaller: return "SSH Setup"
		case .unknown: return "Unknown"
		}
	}

	// The Virtualization-framework class the engine instantiates for this kind — mirrors
	// VMDevices.swift assembly, which switches on the boot mode (macOS guests get the Mac
	// device classes, EFI/kernel boots the generic ones). nil only for .unknown.
	public func vzClassName(macGuest: Bool) -> String? {
		switch self {
		case .keyboard:
			return macGuest ? "VZMacKeyboardConfiguration" : "VZUSBKeyboardConfiguration"
		case .trackpad: return "VZMacTrackpadConfiguration"
		case .pointer: return "VZUSBScreenCoordinatePointingDeviceConfiguration"
		case .graphics:
			return macGuest
				? "VZMacGraphicsDeviceConfiguration" : "VZVirtioGraphicsDeviceConfiguration"
		case .audioInput, .audioOutput: return "VZVirtioSoundDeviceConfiguration"
		case .network: return "VZVirtioNetworkDeviceConfiguration"
		case .clipboard: return "VZVirtioConsoleDeviceConfiguration"
		case .entropy: return "VZVirtioEntropyDeviceConfiguration"
		case .rosetta: return "VZLinuxRosettaDirectoryShare"
		case .consoleLoginInstaller, .sshInstaller:
			return "VZVirtioFileSystemDeviceConfiguration"
		case .unknown: return nil
		}
	}

	// "Mac" / "Generic" where the distinction is meaningful: the split kinds (keyboard,
	// graphics — resolved by boot mode) and the inherently one-sided pointing devices.
	// nil = platform-independent virtio device, no variant row.
	public func variantLabel(macGuest: Bool) -> String? {
		switch self {
		case .keyboard, .graphics: return macGuest ? "Mac" : "Generic"
		case .trackpad, .consoleLoginInstaller: return "Mac"
		case .pointer: return "Generic (USB)"
		default: return nil
		}
	}
}
