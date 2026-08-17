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
	// Superseded by .guestSetup (1.0.7) — kept so old payloads/configs still decode.
	case consoleLoginInstaller
	// Any guest: a read-only share carrying a generated script that enables sshd in the
	// guest and exchanges keys, plus a writable drop-box the guest reports back through.
	// Superseded by .guestSetup (1.0.7) — kept so old payloads/configs still decode.
	case sshInstaller
	// Any guest (1.0.7): the unified installer — a read-only share carrying one generated
	// script that sets up everything guest-side (console logins, kernel console, SSH,
	// sshfs, boot automounts), plus a writable drop-box the guest reports back through.
	case guestSetup
	case unknown       // decode fallback only; never encode it

	// Every real kind, for pickers/validation (excludes the .unknown decode fallback).
	public static let allKinds: [DeviceKind] = [
		.keyboard, .trackpad, .pointer, .graphics, .audioInput, .audioOutput,
		.network, .clipboard, .entropy, .rosetta, .consoleLoginInstaller, .sshInstaller,
		.guestSetup,
	]

	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = DeviceKind(rawValue: raw) ?? .unknown
	}
}

// Shared vocabulary for the login installer: the reserved directory name it appears
// under inside the automounting share ("My Shared Files" is the ONE volume macOS guests
// mount on their own — its name is fixed by the OS, so the installer rides it as a
// folder next to the VM's regular mounts; the name is also a reserved mount tag), the
// script name, and the guest commands. One home so the engine (generation), the daemon
// (tag validation), and the UI (shown commands) can never drift.
public enum ConsoleLoginInstallerInfo {
	public static let directoryName = "LoginInstaller"
	public static let scriptName = "install.sh"

	// The one guest command — the share automounts on macOS 13+, nothing to mount.
	public static var runCommand: String {
		"sudo sh \"/Volumes/My Shared Files/\(directoryName)/\(scriptName)\""
	}

	// macOS 12 guests don't automount; mount the share by hand, then run from there.
	public static var fallbackMountCommand: String {
		"mkdir -p ~/shared && mount_virtiofs com.apple.virtio-fs.automount ~/shared"
	}
}

// Shared vocabulary for the SSH installer (the ConsoleLoginInstallerInfo pattern): the
// read-only payload directory (generated script + the host's public keys), the writable
// drop-box the guest reports back through, and the guest commands. One home so the engine
// (generation), the daemon (tag validation), and the UI (shown commands) can never drift.
public enum SSHSetupInfo {
	public static let directoryName = "SSHSetup"
	public static let reportDirectoryName = "SSHReport"
	public static let scriptName = "install.sh"
	public static let reportName = "report.env"

	// The commands, unprivileged: what needs root is decided by the caller, because the
	// guest may have sudo, doas, or neither (FreeBSD base ships no sudo at all).
	// Guest-side paths come from GuestPaths — never spelled out again here.

	// The installer, wherever the share landed. The default is the standard mount point,
	// so this is the same sentence on every guest that mounts by hand.
	public static func runCommand(inShareAt mountPoint: String = GuestPaths.share) -> String {
		"sh \(mountPoint)/\(directoryName)/\(scriptName)"
	}

	public static var runFromAutomountCommand: String {
		"sh \"\(GuestPaths.macOSAutomount)/\(directoryName)/\(scriptName)\""
	}

	// Prefixes EVERY command in an && chain — "sudo a && b" would run b as the user.
	public static func escalated(_ command: String, with prefix: String) -> String {
		guard !prefix.isEmpty else { return command }
		return command.components(separatedBy: " && ")
			.map { prefix + $0 }
			.joined(separator: " && ")
	}

	// macOS guests: the share automounts on 13+, nothing to mount.
	public static var runCommand: String {
		escalated(runFromAutomountCommand, with: "sudo ")
	}

	// Linux guests mount the share by hand once, then run from inside it.
	public static var mountAndRunCommand: String {
		escalated(GuestPaths.mountShareCommand + " && " + runCommand(), with: "sudo ")
	}
}

// Shared vocabulary for the unified guest-setup installer (1.0.7, the SSHSetupInfo
// pattern): the read-only payload directory (generated script + env + keys + mount list),
// the writable drop-box the guest reports back through, and the guest commands. One home
// so the engine (generation), the daemon (tag validation), and the UI (shown commands)
// can never drift.
public enum GuestSetupInstallerInfo {
	public static let directoryName = "GuestSetup"
	public static let reportDirectoryName = "GuestReport"
	public static let scriptName = "install.sh"
	public static let reportName = "report.env"
	// Per-mount hand-off beside the script: `kind<TAB>name<TAB>hostpath` lines.
	public static let mountsFileName = "mounts.list"

	// The installer, wherever the share landed (see SSHSetupInfo for the escalation rules).
	public static func runCommand(inShareAt mountPoint: String = GuestPaths.share) -> String {
		"sh \(mountPoint)/\(directoryName)/\(scriptName)"
	}

	public static var runFromAutomountCommand: String {
		"sh \"\(GuestPaths.macOSAutomount)/\(directoryName)/\(scriptName)\""
	}

	// macOS guests: the share automounts on 13+, nothing to mount.
	public static var runCommand: String {
		SSHSetupInfo.escalated(runFromAutomountCommand, with: "sudo ")
	}

	// Linux guests mount the share by hand once, then run from inside it.
	public static var mountAndRunCommand: String {
		SSHSetupInfo.escalated(
			GuestPaths.mountShareCommand + " && " + runCommand(), with: "sudo ")
	}
}

// Share-directory names the engine reserves for generated payloads. They ride the same
// virtiofs share as the user's mounts, so mount validation refuses them as tags — one
// home so validation and generation can never drift. The pre-1.0.7 names stay reserved:
// old daemons still generate them, and a user tag matching one would collide on downgrade.
public enum ReservedShareNames {
	public static var all: Set<String> {
		[ConsoleLoginInstallerInfo.directoryName,
			SSHSetupInfo.directoryName, SSHSetupInfo.reportDirectoryName,
			GuestSetupInstallerInfo.directoryName,
			GuestSetupInstallerInfo.reportDirectoryName]
	}
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
