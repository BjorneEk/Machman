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

// A serial port as served over the API. Counts come from the array lengths in VMInfo. socketPath
// is present only while the VM runs (the vmhost serves it); mmioBase/irq are present only for
// uart ports once platform info has been generated. guestDevice/logPath are informational.
public struct SerialPortInfo: Codable, Sendable, Equatable, Identifiable {
	public var kind: SerialPortKind
	public var index: Int
	public var guestDevice: String        // e.g. "hvc0", "ttyAMA0", "cu.virtio0"
	public var logging: SerialLogConfig
	public var socketPath: String?        // live data-plane socket; nil when stopped
	public var logPath: String?           // on-disk log file when logging is enabled
	public var mmioBase: String?          // uart only, from generated platform info
	public var irq: Int?                  // uart only, from generated platform info

	public var id: String { "\(kind.rawValue)\(index)" }

	public init(
		kind: SerialPortKind, index: Int, guestDevice: String, logging: SerialLogConfig,
		socketPath: String? = nil, logPath: String? = nil, mmioBase: String? = nil,
		irq: Int? = nil
	) {
		self.kind = kind
		self.index = index
		self.guestDevice = guestDevice
		self.logging = logging
		self.socketPath = socketPath
		self.logPath = logPath
		self.mmioBase = mmioBase
		self.irq = irq
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
	}
}
