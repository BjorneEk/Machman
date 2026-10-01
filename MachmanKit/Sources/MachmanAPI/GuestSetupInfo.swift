//
//  GuestSetupInfo.swift
//  MachmanAPI
//
//  Per-VM guest-setup state as served over the API (1.0.7): what the unified installer
//  script reported from inside the guest — the detected OS, what each feature could and
//  did configure, the errors it hit, and the boot automounts it wrote. Persisted facts are
//  owned by whichever process owns the config (the SSHInfo pattern); the one server-only
//  field is currentScriptVersion, which describes the app, not the guest. Statuses,
//  feature ids and mount kinds are PLAIN strings — a value written by a newer daemon must
//  survive this one's round trip.
//

import Foundation

// The feature ids the script reports today. A plain-string vocabulary, not an enum:
// clients render unknown ids verbatim instead of dropping them.
public enum GuestFeature {
	public static let console = "console"
	public static let kernelConsole = "kernelConsole"
	public static let ssh = "ssh"
	public static let reverseSSH = "reverseSSH"
	public static let sshfs = "sshfs"
	public static let virtiofsAutomount = "virtiofsAutomount"
	public static let sshfsAutomount = "sshfsAutomount"
}

// How a mount reaches the guest. Plain strings (see GuestFeature).
public enum MountKind {
	public static let virtiofs = "virtiofs"
	public static let sshfs = "sshfs"
}

// One error a script run reported: the named step that failed and its one-sentence message.
public struct GuestSetupError: Codable, Sendable, Equatable {
	public var step: String
	public var message: String

	public init(step: String, message: String) {
		self.step = step
		self.message = message
	}
}

// One informational line a script run reported (a repair it made, a boot-time refresh that
// will not run): no failure — the errors' {step, message} shape.
public typealias GuestSetupNote = GuestSetupError

// One feature as the script saw it on this guest: whether the OS can do it at all (with
// the reason when it cannot), whether it is configured, and a one-line detail for the UI
// ("gustaf", "hvc0, hvc1", "2 automounts").
public struct GuestFeatureInfo: Codable, Sendable, Equatable, Identifiable {
	public var id: String            // a GuestFeature value; unknown ids render verbatim
	public var available: Bool
	public var reason: String?       // why unavailable, when it is
	public var configured: Bool
	public var detail: String?

	public init(
		id: String, available: Bool, reason: String? = nil, configured: Bool,
		detail: String? = nil
	) {
		self.id = id
		self.available = available
		self.reason = reason
		self.configured = configured
		self.detail = detail
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try c.decode(String.self, forKey: .id)
		self.available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
		self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
		self.configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
		self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
	}
}

// One console interface as the script found it: the guest device name, its login state
// ("active" — a getty is running, "configured" — one is set up for the next boot,
// "none"), whether it is the kernel console (console= points at it), and whether the
// login was configured OUTSIDE Machman (present, unmarked, left as is).
public struct GuestConsoleInfo: Codable, Sendable, Equatable, Identifiable {
	public var device: String        // "hvc0", "ttyV0.0", "cu.virtio"
	public var login: String
	public var kernelConsole: Bool?
	// The kernel console is CONFIGURED for this device but the guest has not rebooted
	// into it yet (kernelConsole reflects the running kernel only).
	public var kernelConsolePending: Bool?
	public var external: Bool?

	public var id: String { device }

	public init(
		device: String, login: String, kernelConsole: Bool? = nil,
		kernelConsolePending: Bool? = nil, external: Bool? = nil
	) {
		self.device = device
		self.login = login
		self.kernelConsole = kernelConsole
		self.kernelConsolePending = kernelConsolePending
		self.external = external
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.device = try c.decode(String.self, forKey: .device)
		self.login = try c.decodeIfPresent(String.self, forKey: .login) ?? "none"
		self.kernelConsole = try c.decodeIfPresent(Bool.self, forKey: .kernelConsole)
		self.kernelConsolePending =
			try c.decodeIfPresent(Bool.self, forKey: .kernelConsolePending)
		self.external = try c.decodeIfPresent(Bool.self, forKey: .external)
	}
}

// One boot automount the script configured: how it arrives (a MountKind), what it mounts
// (the share tag or the mount's name), and where in the guest it lands.
public struct GuestAutomountInfo: Codable, Sendable, Equatable {
	public var kind: String          // a MountKind value
	public var target: String
	public var path: String

	public init(kind: String, target: String, path: String) {
		self.kind = kind
		self.target = target
		self.path = path
	}
}

public struct GuestSetupInfo: Codable, Sendable, Equatable {
	// A report is on file and the last run did not uninstall.
	public var installed: Bool?
	// Detected guest — /etc/os-release ID (or "darwin"/"freebsd"…), family, version, init.
	public var guestOS: String?
	public var guestOSFamily: String?
	public var guestOSVersion: String?
	public var guestInit: String?
	public var lastReportAt: Date?         // stamped by the HOST at ingestion
	public var scriptVersion: Int?         // the script version that produced the report
	public var currentScriptVersion: Int?  // the version this app ships (server-resolved)
	public var lastRunStatus: String?      // "ok" | "partial" | "failed" — plain string
	public var lastRunNote: String?
	public var lastTransport: String?      // "virtiofs" | "sshfs" | "local"
	public var errors: [GuestSetupError]?
	// Informational lines from the last run, never failures (additive; nil = none).
	public var notes: [GuestSetupNote]?
	public var features: [GuestFeatureInfo]?
	public var consoles: [GuestConsoleInfo]?
	public var automounts: [GuestAutomountInfo]?
	// The user asked for a reinstall/update: the installer is served again
	// (vm.setup.serve; additive 1.0.7). nil = false.
	public var reinstallRequested: Bool?

	public init(
		installed: Bool? = nil,
		guestOS: String? = nil, guestOSFamily: String? = nil, guestOSVersion: String? = nil,
		guestInit: String? = nil, lastReportAt: Date? = nil, scriptVersion: Int? = nil,
		currentScriptVersion: Int? = nil, lastRunStatus: String? = nil,
		lastRunNote: String? = nil, lastTransport: String? = nil,
		errors: [GuestSetupError]? = nil, notes: [GuestSetupNote]? = nil,
		features: [GuestFeatureInfo]? = nil,
		consoles: [GuestConsoleInfo]? = nil, automounts: [GuestAutomountInfo]? = nil,
		reinstallRequested: Bool? = nil
	) {
		self.installed = installed
		self.guestOS = guestOS
		self.guestOSFamily = guestOSFamily
		self.guestOSVersion = guestOSVersion
		self.guestInit = guestInit
		self.lastReportAt = lastReportAt
		self.scriptVersion = scriptVersion
		self.currentScriptVersion = currentScriptVersion
		self.lastRunStatus = lastRunStatus
		self.lastRunNote = lastRunNote
		self.lastTransport = lastTransport
		self.errors = errors
		self.notes = notes
		self.features = features
		self.consoles = consoles
		self.automounts = automounts
		self.reinstallRequested = reinstallRequested
	}

	// Tolerant decode; encode stays synthesized so nil optionals are omitted.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
		self.guestOS = try c.decodeIfPresent(String.self, forKey: .guestOS)
		self.guestOSFamily = try c.decodeIfPresent(String.self, forKey: .guestOSFamily)
		self.guestOSVersion = try c.decodeIfPresent(String.self, forKey: .guestOSVersion)
		self.guestInit = try c.decodeIfPresent(String.self, forKey: .guestInit)
		self.lastReportAt = try c.decodeIfPresent(Date.self, forKey: .lastReportAt)
		self.scriptVersion = try c.decodeIfPresent(Int.self, forKey: .scriptVersion)
		self.currentScriptVersion =
			try c.decodeIfPresent(Int.self, forKey: .currentScriptVersion)
		self.lastRunStatus = try c.decodeIfPresent(String.self, forKey: .lastRunStatus)
		self.lastRunNote = try c.decodeIfPresent(String.self, forKey: .lastRunNote)
		self.lastTransport = try c.decodeIfPresent(String.self, forKey: .lastTransport)
		self.errors = try c.decodeIfPresent([GuestSetupError].self, forKey: .errors)
		self.notes = try c.decodeIfPresent([GuestSetupNote].self, forKey: .notes)
		self.features = try c.decodeIfPresent([GuestFeatureInfo].self, forKey: .features)
		self.consoles = try c.decodeIfPresent([GuestConsoleInfo].self, forKey: .consoles)
		self.automounts =
			try c.decodeIfPresent([GuestAutomountInfo].self, forKey: .automounts)
		self.reinstallRequested =
			try c.decodeIfPresent(Bool.self, forKey: .reinstallRequested)
	}
}
