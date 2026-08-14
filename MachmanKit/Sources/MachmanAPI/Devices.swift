//
//  Devices.swift
//  MachmanAPI
//
//  Guest-device vocabulary (wire 1.0.4). Every device the engine attaches to a VM is
//  described by a DeviceInfo; the list lives at VMInfo.devices. nil devices = an older
//  daemon — clients derive the implied per-boot set instead (what the engine hard-coded
//  before devices were configurable). One device per kind; VZ itself caps graphics at one
//  display. USB is deliberately absent (waiting on macOS 27 passthrough); .iso disks keep
//  their boot-time USB mass-storage attachment independent of this list.
//

import Foundation

// Which device a DeviceInfo describes. Tolerant decode: an unrecognized future kind
// degrades to .unknown instead of failing the whole VMInfo decode.
public enum DeviceKind: String, Codable, Sendable, Equatable {
	case keyboard      // VZMacKeyboard (macOS boot) / VZUSBKeyboard (EFI, kernel)
	case trackpad      // VZMacTrackpad — macOS boot only (needs a macOS 13+ guest)
	case pointer       // VZUSBScreenCoordinatePointingDevice
	case graphics      // VZMacGraphics / VZVirtioGraphics, exactly one display
	case audioInput    // VZVirtioSound device with the host's default microphone
	case audioOutput   // VZVirtioSound device with the host's default output
	case network       // VZVirtioNetwork + NAT; the MAC stays VMInfo.macAddress
	case clipboard     // spice agent console port — EFI/kernel boots only
	case entropy       // VZVirtioEntropyDevice
	case rosetta       // VZLinuxRosettaDirectoryShare (tag "rosetta") — EFI/kernel boots
	// macOS guests only: a read-only share carrying a generated install script that sets
	// up login prompts (launchd gettys) on the VM's virtio consoles from inside the guest.
	case consoleLoginInstaller
	case unknown       // decode fallback only; never encode it

	// Every real kind, for pickers/validation (excludes the .unknown decode fallback).
	public static let allKinds: [DeviceKind] = [
		.keyboard, .trackpad, .pointer, .graphics, .audioInput, .audioOutput,
		.network, .clipboard, .entropy, .rosetta, .consoleLoginInstaller,
	]

	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = DeviceKind(rawValue: raw) ?? .unknown
	}
}

// Shared names for the login installer's payload: the reserved share-directory name
// (also a reserved mount tag) and the script inside it. On a macOS guest the share
// automounts, so the full path is /Volumes/My Shared Files/<directoryName>/<scriptName>.
// One home so the engine (generation), the daemon (tag validation), and the UI (shown
// commands) can never drift.
public enum ConsoleLoginInstallerInfo {
	public static let directoryName = "login-installer"
	public static let scriptName = "install.sh"
}

// Why something configured on a VM cannot be used on this host (a gated uart, Rosetta not
// installed, nested virtualization unsupported…). Generalized from the serial-port shape —
// same wire keys; SerialPortUnavailability remains as a typealias.
public struct UnavailabilityInfo: Codable, Sendable, Equatable {
	public enum Reason: String, Codable, Sendable, Equatable {
		case privateUARTGated   // macOS >= SerialPortSupport.privateUARTGatedSince
		case classUnavailable   // a required private class is absent from this runtime
		case notInstalled       // host component missing but installable (Rosetta)
		case unsupportedHost    // this hardware/OS cannot do it (nested virt pre-M3)
		case unknown            // forward-compat: unrecognized future reasons decode to this
	}

	public var reason: Reason
	public var message: String          // human-readable, ready to surface to a user
	public var sinceOSVersion: String?  // the gate's macOS version, when version-based

	public init(reason: Reason, message: String, sinceOSVersion: String? = nil) {
		self.reason = reason
		self.message = message
		self.sinceOSVersion = sinceOSVersion
	}

	// Tolerant decode: an unrecognized future reason degrades to .unknown rather than failing.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.reason = Reason(rawValue: try c.decode(String.self, forKey: .reason)) ?? .unknown
		self.message = try c.decode(String.self, forKey: .message)
		self.sinceOSVersion = try c.decodeIfPresent(String.self, forKey: .sinceOSVersion)
	}
}

// A guest device as served over the API. Settings are flat optionals (only meaningful for
// some kinds); `unavailable` is computed by the daemon per host and never persisted.
public struct DeviceInfo: Codable, Sendable, Equatable, Identifiable {
	public var kind: DeviceKind
	// Disabled devices stay configured but are not attached at the next start. Non-optional
	// with a default-true decode (the windowOpen pattern) — daemons always populate it.
	public var enabled: Bool
	public var displayWidthPixels: Int?      // graphics
	public var displayHeightPixels: Int?     // graphics
	public var displayPixelsPerInch: Int?    // graphics, macOS guests
	public var sharesClipboard: Bool?        // clipboard
	public var unavailable: UnavailabilityInfo?

	public var id: String { kind.rawValue }

	public init(
		kind: DeviceKind, enabled: Bool = true,
		displayWidthPixels: Int? = nil, displayHeightPixels: Int? = nil,
		displayPixelsPerInch: Int? = nil, sharesClipboard: Bool? = nil,
		unavailable: UnavailabilityInfo? = nil
	) {
		self.kind = kind
		self.enabled = enabled
		self.displayWidthPixels = displayWidthPixels
		self.displayHeightPixels = displayHeightPixels
		self.displayPixelsPerInch = displayPixelsPerInch
		self.sharesClipboard = sharesClipboard
		self.unavailable = unavailable
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.kind = try c.decode(DeviceKind.self, forKey: .kind)
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		self.displayWidthPixels = try c.decodeIfPresent(Int.self, forKey: .displayWidthPixels)
		self.displayHeightPixels =
			try c.decodeIfPresent(Int.self, forKey: .displayHeightPixels)
		self.displayPixelsPerInch =
			try c.decodeIfPresent(Int.self, forKey: .displayPixelsPerInch)
		self.sharesClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharesClipboard)
		self.unavailable = try c.decodeIfPresent(UnavailabilityInfo.self, forKey: .unavailable)
	}
}

// The implied device set for VMs whose config predates configurable devices — exactly what
// the engine used to attach unconditionally per boot mode. Shared by the daemon's config
// migration and by clients rendering a nil VMInfo.devices from an older daemon.
public enum ImpliedDevices {
	public static func kinds(macGuest: Bool) -> [DeviceKind] {
		if macGuest {
			return [.keyboard, .trackpad, .pointer, .graphics, .audioInput, .audioOutput,
				.network]
		}
		return [.keyboard, .pointer, .graphics, .audioInput, .audioOutput, .network,
			.clipboard]
	}
}
