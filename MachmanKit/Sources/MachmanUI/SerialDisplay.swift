//
//  SerialDisplay.swift
//  MachmanUI
//
//  Display names for serial ports, by the VM's boot mode. The wire guestDevice field stays
//  the truthful device name (sockets, logs, scripts); what the UI CALLS a port depends on
//  what the boot mode proves about the guest: a kernel boot is Linux by construction (keep
//  hvcN / ttyAMAN), a macOS guest keeps its real cu.virtio name, and an EFI guest can boot
//  anything → neutral "Console N" / "UART N" (0-based, so the number lines up with the
//  per-OS device rows in the inspector: hvc0 / ttyV0.0).
//

import Foundation
import MachmanAPI

public extension SerialPortKind {
	func displayName(guestIndex: Int, mode: BootInfo.Mode) -> String {
		switch (self, mode) {
		case (.console, .efi):
			return "Console \(guestIndex)"
		case (.uart, .efi), (.uart, .macOS):
			return "UART \(guestIndex)"
		case (.console, .linuxKernel), (.console, .macOS), (.uart, .linuxKernel):
			return guestDevice(index: guestIndex, os: mode == .macOS ? .macOS : .linux)
		}
	}
}

public extension SerialPortInfo {
	// guestIndex is the enabled-compacted number the guest sees; an older daemon doesn't
	// send it — fall back to the config index (its guestDevice is config-indexed anyway).
	// A guest-reported name beats every convention: once the setup run has SEEN the
	// device, "Console 0" becomes "ttyV0.0" — no OS guessing.
	func displayName(mode: BootInfo.Mode) -> String {
		guestName ?? kind.displayName(guestIndex: guestIndex ?? index, mode: mode)
	}

	// The inspector spelling: a known name (or a mode that proves the OS) earns the
	// /dev/ prefix; an EFI port nobody has reported stays the neutral display name —
	// EFI guarantees no OS, so no device path is claimed.
	func deviceLabel(mode: BootInfo.Mode) -> String {
		if let guestName { return "/dev/" + guestName }
		if mode == .efi { return kind.displayName(guestIndex: guestIndex ?? index, mode: mode) }
		return "/dev/" + guestDevice
	}
}

public extension SerialPortRef {
	// Best effort without the DTO (VM gone / port not served): the config index.
	func displayName(mode: BootInfo.Mode) -> String {
		kind.displayName(guestIndex: index, mode: mode)
	}
}
