//
//  SerialPort.swift
//  MachmanAPI
//
//  Serial-port vocabulary shared by the persisted config and the wire. A VM has some number of
//  console ports (virtio, guest /dev/hvc*) and some number of UART ports (PL011, guest
//  /dev/ttyAMA*); the count is the only structural config. Each port carries a logging config.
//  These types are persisted directly by VMConfig (like StartPolicy) so there is no mirror to
//  keep in lockstep.
//

import Foundation

// Which family a serial port belongs to. Console = virtio console (needs a virtio driver in the
// guest); uart = PL011 (drivable by bare-metal / minimal kernels).
public enum SerialPortKind: String, Codable, Sendable, Equatable {
	case console
	case uart

	// The guest device name for the index-th port of this kind. Linux console ports enumerate
	// hvc0, hvc1…; UARTs ttyAMA0, ttyAMA1…. A macOS guest surfaces virtio consoles as
	// /dev/cu.virtio[N]; its UART path is not a userland tty (kernel debug channel), reported
	// with the Linux name for reference.
	public func guestDevice(index: Int, macGuest: Bool) -> String {
		switch self {
		case .console:
			if macGuest { return index == 0 ? "cu.virtio" : "cu.virtio\(index)" }
			return "hvc\(index)"
		case .uart:
			return "ttyAMA\(index)"
		}
	}
}

// How the vmhost records a serial port's output to a file, alongside the always-served socket.
public enum SerialLogMode: String, Codable, Sendable, Equatable {
	case disabled       // no file; the socket is the only sink
	case resetOnBoot    // overwrite the file on each boot (the default)
	case continuous     // append across boots
}

public struct SerialLogConfig: Codable, Sendable, Equatable {
	public var mode: SerialLogMode
	// Cap the log file at this many bytes (oldest trimmed); nil = unlimited (the default).
	public var maxBytes: UInt64?

	public init(mode: SerialLogMode = .resetOnBoot, maxBytes: UInt64? = nil) {
		self.mode = mode
		self.maxBytes = maxBytes
	}

	// Tolerant decode: absent mode defaults, and an unrecognized future mode degrades to the
	// default rather than failing the whole config/VMInfo decode.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let raw = try c.decodeIfPresent(String.self, forKey: .mode) ?? SerialLogMode.resetOnBoot.rawValue
		self.mode = SerialLogMode(rawValue: raw) ?? .resetOnBoot
		self.maxBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxBytes)
	}
}

// The macOS release at which Virtualization.framework began gating the private PL011/16550 serial
// devices behind the com.apple.private.virtualization entitlement. At or above this version an
// unentitled host (Machman) can no longer attach them, so configured uart ports are inert and are
// reported with a SerialPortInfo.unavailable reason. See
// docs/local/socket-research/research-findings.md §3.
public enum SerialPortSupport {
	public static let privateUARTGatedSince = OperatingSystemVersion(
		majorVersion: 26, minorVersion: 6, patchVersion: 1)

	// The gate version as a plain "major.minor.patch" string, for messages and the wire.
	public static var privateUARTGatedSinceDisplay: String {
		let v = privateUARTGatedSince
		return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
	}
}

// Why a configured serial port is present in the VM's config but cannot actually be attached on
// this host — currently only uart ports, where the private PL011 device is gated (see
// SerialPortSupport). nil means the port works here.
public struct SerialPortUnavailability: Codable, Sendable, Equatable {
	public enum Reason: String, Codable, Sendable, Equatable {
		case privateUARTGated   // macOS >= SerialPortSupport.privateUARTGatedSince: entitlement gate
		case classUnavailable   // the private serial class is absent from this runtime
		case unknown            // forward-compat: an unrecognized future reason decodes to this
	}

	public var reason: Reason
	public var message: String          // human-readable, ready to surface to a user
	public var sinceOSVersion: String?  // the gate's macOS version, when the reason is version-based

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

// A serial port as served over the API. Counts come from the array lengths in VMInfo. socketPath
// is present only while the VM runs (the vmhost serves it); mmioBase/irq are present only for
// uart ports once platform info has been generated; unavailable is set when a configured port
// cannot be attached on this host (a gated uart). guestDevice/logPath are informational.
public struct SerialPortInfo: Codable, Sendable, Equatable, Identifiable {
	public var kind: SerialPortKind
	public var index: Int
	public var guestDevice: String        // e.g. "hvc0", "ttyAMA0", "cu.virtio0"
	public var logging: SerialLogConfig
	public var socketPath: String?        // live data-plane socket; nil when stopped
	public var logPath: String?           // on-disk log file when logging is enabled
	public var mmioBase: String?          // uart only, from generated platform info
	public var irq: Int?                  // uart only, from generated platform info
	public var unavailable: SerialPortUnavailability?  // set when a configured port can't attach here

	public var id: String { "\(kind.rawValue)\(index)" }

	public init(
		kind: SerialPortKind, index: Int, guestDevice: String, logging: SerialLogConfig,
		socketPath: String? = nil, logPath: String? = nil, mmioBase: String? = nil,
		irq: Int? = nil, unavailable: SerialPortUnavailability? = nil
	) {
		self.kind = kind
		self.index = index
		self.guestDevice = guestDevice
		self.logging = logging
		self.socketPath = socketPath
		self.logPath = logPath
		self.mmioBase = mmioBase
		self.irq = irq
		self.unavailable = unavailable
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.kind = try c.decode(SerialPortKind.self, forKey: .kind)
		self.index = try c.decode(Int.self, forKey: .index)
		self.guestDevice = try c.decode(String.self, forKey: .guestDevice)
		self.logging = try c.decodeIfPresent(SerialLogConfig.self, forKey: .logging)
			?? SerialLogConfig()
		self.socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath)
		self.logPath = try c.decodeIfPresent(String.self, forKey: .logPath)
		self.mmioBase = try c.decodeIfPresent(String.self, forKey: .mmioBase)
		self.irq = try c.decodeIfPresent(Int.self, forKey: .irq)
		self.unavailable = try c.decodeIfPresent(SerialPortUnavailability.self, forKey: .unavailable)
	}
}
