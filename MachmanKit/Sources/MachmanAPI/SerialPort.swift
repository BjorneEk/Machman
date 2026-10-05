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

// Guest operating systems we can name serial devices for. A kernel boot is Linux by
// construction; an EFI guest can be any of the non-mac ones — device names are per-OS
// conventions, so the UI shows the plausible set instead of assuming Linux.
public enum SerialGuestOS: String, Codable, Sendable {
	case linux
	case freebsd
	case macOS
}

// Which family a serial port belongs to. Console = virtio console (needs a virtio driver in the
// guest); uart = PL011 (drivable by bare-metal / minimal kernels). Tolerant decode (1.0.8): an
// unrecognized future family degrades to .unknown instead of failing the whole vm.list decode;
// the daemon rejects .unknown in requests.
public enum SerialPortKind: String, Codable, Sendable, Equatable {
	case console
	case uart
	case unknown   // decode fallback only; never encode it

	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = SerialPortKind(rawValue: raw) ?? .unknown
	}

	// The guest device name for the index-th port of this kind. Linux console ports enumerate
	// hvc0, hvc1…; FreeBSD sees each (single-port) virtio-console device as ttyV<unit>.0 once
	// virtio_console.ko is loaded; a macOS guest surfaces them as /dev/cu.virtio[N]. UARTs:
	// Linux ttyAMA*, FreeBSD ttyu*; on a macOS guest the PL011 is the kernel debug channel
	// with no userland tty, reported with the Linux name for reference.
	public func guestDevice(index: Int, os: SerialGuestOS) -> String {
		switch (self, os) {
		case (.console, .linux):
			return "hvc\(index)"
		case (.console, .freebsd):
			return "ttyV\(index).0"
		case (.console, .macOS):
			return index == 0 ? "cu.virtio" : "cu.virtio\(index)"
		case (.uart, .linux), (.uart, .macOS):
			return "ttyAMA\(index)"
		case (.uart, .freebsd):
			return "ttyu\(index)"
		case (.unknown, _):
			// A future family this build can't name; the wire's guestDevice field is
			// what real payloads carry.
			return "serial\(index)"
		}
	}

	// Two-way spelling used by the daemon's baked guestDevice: mac or "the Linux name".
	public func guestDevice(index: Int, macGuest: Bool) -> String {
		guestDevice(index: index, os: macGuest ? .macOS : .linux)
	}
}

// How the vmhost records a serial port's output to a file, alongside the always-served socket.
public enum SerialLogMode: String, Codable, Sendable, Equatable {
	case disabled       // no file; the socket is the only sink
	case resetOnBoot    // overwrite the file on each boot (the default)
	case continuous     // append across boots
}

public struct SerialLogConfig: Codable, Sendable, Equatable {
	// The mode as written, on disk and on the wire (D26 — the GuestDevice.kind lesson): a
	// newer Machman's mode survives this build's load and save verbatim. Read and set it
	// through `mode`.
	public private(set) var rawMode: String
	// Cap the log file at this many bytes (oldest trimmed); nil = unlimited (the default).
	public var maxBytes: UInt64?

	// An unrecognized (newer) mode logs like the default here; setting one replaces it.
	public var mode: SerialLogMode {
		get { SerialLogMode(rawValue: rawMode) ?? .resetOnBoot }
		set { rawMode = newValue.rawValue }
	}

	public init(mode: SerialLogMode = .resetOnBoot, maxBytes: UInt64? = nil) {
		self.rawMode = mode.rawValue
		self.maxBytes = maxBytes
	}

	private enum CodingKeys: String, CodingKey {
		case mode
		case maxBytes
	}

	// Tolerant decode: an absent mode defaults, and an unrecognized one is kept rather than
	// failing the whole config/VMInfo decode.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.rawMode = try c.decodeIfPresent(String.self, forKey: .mode)
			?? SerialLogMode.resetOnBoot.rawValue
		self.maxBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxBytes)
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(rawMode, forKey: .mode)
		try c.encodeIfPresent(maxBytes, forKey: .maxBytes)
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

// Why a configured serial port cannot actually be attached on this host. The struct was
// generalized to UnavailabilityInfo (Devices.swift) for device-level gating too — same wire
// shape, this name kept for source compatibility.
public typealias SerialPortUnavailability = UnavailabilityInfo

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
	// Disabled ports stay configured but are not attached at the next start (guest names
	// renumber, same as removal). Tri-state, nil = enabled (DiskInfo pattern).
	public var enabled: Bool?
	// The index baked into guestDevice: enabled ports numbered compactly, as the guest sees
	// them at the next boot (`index` is the config position). nil = older daemon — fall back
	// to `index`.
	public var guestIndex: Int?
	// 1.0.7: the device name the GUEST itself reported for this port (a setup run found
	// it: "ttyV0.0", "hvc0", …). nil until then — guestDevice above stays the boot-mode
	// guess, this is the truth once the guest has spoken.
	public var guestName: String?

	public var id: String { "\(kind.rawValue)\(index)" }

	public init(
		kind: SerialPortKind, index: Int, guestDevice: String, logging: SerialLogConfig,
		socketPath: String? = nil, logPath: String? = nil, mmioBase: String? = nil,
		irq: Int? = nil, unavailable: SerialPortUnavailability? = nil, enabled: Bool? = nil,
		guestIndex: Int? = nil, guestName: String? = nil
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
		self.enabled = enabled
		self.guestIndex = guestIndex
		self.guestName = guestName
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
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
		self.guestIndex = try c.decodeIfPresent(Int.self, forKey: .guestIndex)
		self.guestName = try c.decodeIfPresent(String.self, forKey: .guestName)
	}

	public var isEnabled: Bool { enabled ?? true }
}
