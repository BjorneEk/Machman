//
//  GuestDevices.swift
//  MachmanCore
//
//  Persisted guest-device config (wire 1.0.4). A VM's `devices` array in its on-disk config
//  declares which devices the engine attaches at start; configs predating the key get the
//  implied per-boot set synthesized at load (presence-sentinel migration, like the serial
//  ports). Kind is a plain string on disk so a config written by a NEWER daemon keeps its
//  unknown kinds verbatim through an older-1.0.4+ daemon's load/save cycle.
//

import Foundation
import MachmanAPI

struct GuestDevice: Codable, Equatable, Identifiable {
	var kind: String
	var enabled: Bool = true
	// Flat per-kind settings (VMDiskKind lesson: never an enum with associated values).
	var displayWidthPixels: Int?
	var displayHeightPixels: Int?
	var displayPixelsPerInch: Int?
	// Raw on disk (the kind precedent): a NEWER daemon's future mode survives this daemon's
	// load/save cycle verbatim. Read through systemKeyCaptureMode.
	var systemKeyCapture: String?
	var sharesClipboard: Bool?

	var id: String { kind }
	var deviceKind: DeviceKind { DeviceKind(rawValue: kind) ?? .unknown }
	var systemKeyCaptureMode: SystemKeyCapture? {
		systemKeyCapture.map { SystemKeyCapture(rawValue: $0) ?? .unknown }
	}

	init(kind: DeviceKind) {
		self.kind = kind.rawValue
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case enabled
		case displayWidthPixels
		case displayHeightPixels
		case displayPixelsPerInch
		case systemKeyCapture
		case sharesClipboard
	}

	// Tolerant decode: absent enabled defaults true; unknown kinds are preserved verbatim.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.kind = try c.decode(String.self, forKey: .kind)
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		self.displayWidthPixels = try c.decodeIfPresent(Int.self, forKey: .displayWidthPixels)
		self.displayHeightPixels =
			try c.decodeIfPresent(Int.self, forKey: .displayHeightPixels)
		self.displayPixelsPerInch =
			try c.decodeIfPresent(Int.self, forKey: .displayPixelsPerInch)
		self.systemKeyCapture = try c.decodeIfPresent(String.self, forKey: .systemKeyCapture)
		self.sharesClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharesClipboard)
	}
}

extension VMConfig {
	// The device set a config gets when its file predates the devices key — exactly what the
	// engine attached unconditionally before devices became configurable. Shared vocabulary
	// with clients via MachmanAPI.ImpliedDevices.
	static func impliedDevices(for boot: BootConfig) -> [GuestDevice] {
		let macGuest = if case .macOS = boot { true } else { false }
		return ImpliedDevices.kinds(macGuest: macGuest).map(GuestDevice.init)
	}

	// The system-key-capture mode a run starts with: the display device's default, off when
	// unset, unknown (a newer daemon's mode), or there is no display device at all.
	var systemKeyCaptureDefault: SystemKeyCapture {
		let mode = devices.first { $0.deviceKind == .graphics }?.systemKeyCaptureMode ?? .off
		return mode == .unknown ? .off : mode
	}

	// Migration (1.0.7): consoleLoginInstaller + sshInstaller collapse into one guestSetup
	// device — enabled if either was, at the first one's position. Called from load(name:),
	// which saves when this returns true (the VMDisk migrate-on-load precedent).
	func migrateLegacyInstallerDevices() -> Bool {
		let legacy = [
			DeviceKind.consoleLoginInstaller.rawValue, DeviceKind.sshInstaller.rawValue,
		]
		guard devices.contains(where: { legacy.contains($0.kind) }) else { return false }
		let enabled = devices.contains { legacy.contains($0.kind) && $0.enabled }
		let position = devices.firstIndex { legacy.contains($0.kind) } ?? devices.count
		devices.removeAll { legacy.contains($0.kind) }
		if !devices.contains(where: { $0.kind == DeviceKind.guestSetup.rawValue }) {
			var unified = GuestDevice(kind: .guestSetup)
			unified.enabled = enabled
			devices.insert(unified, at: min(position, devices.count))
		}
		return true
	}

	// MARK: - Device mutations (vm.device.*)

	func addDevice(_ device: GuestDevice) throws {
		guard !devices.contains(where: { $0.kind == device.kind }) else {
			let label = DeviceKind.displayLabel(raw: device.kind)
			throw MachmanError(
				code: .alreadyExists, message: "\(name) already has the \(label) device")
		}
		devices.append(device)
		try saveVMConfig()
	}

	func removeDevice(kind: DeviceKind) throws {
		guard devices.contains(where: { $0.deviceKind == kind }) else {
			throw MachmanError(
				code: .notFound, message: "\(name) has no \(kind.displayLabel) device")
		}
		devices.removeAll { $0.deviceKind == kind }
		try saveVMConfig()
	}

	func updateDevice(_ updated: GuestDevice) throws {
		guard let index = devices.firstIndex(where: { $0.kind == updated.kind }) else {
			throw MachmanError(
				code: .notFound,
				message: "\(name) has no \(DeviceKind.displayLabel(raw: updated.kind)) device")
		}
		devices[index] = updated
		try saveVMConfig()
	}

	// MARK: - Enabled flags (vm.setEnabled) — setSafety twin: all-or-nothing precheck.

	// Devices (1.0.12) are keyed by kind, as stored (a newer daemon's kind is addressable too).
	func setEnabled(
		disks diskFlags: [String: Bool], mounts mountFlags: [String: Bool],
		console consoleFlags: [String: Bool], uart uartFlags: [String: Bool],
		devices deviceFlags: [String: Bool] = [:]
	) throws {
		for id in diskFlags.keys where !disks.contains(where: { $0.id == id }) {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		for id in mountFlags.keys
			where !mountPoints.contains(where: { $0.id.uuidString == id }) {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that mount")
		}
		for kind in deviceFlags.keys where !devices.contains(where: { $0.kind == kind }) {
			throw MachmanError(
				code: .notFound,
				message: "\(name) has no \(DeviceKind.displayLabel(raw: kind)) device")
		}
		// Serial ports arrive as string indices ("0", "1"…) — JSON-object keys on the wire.
		func parsed(_ flags: [String: Bool], count: Int, what: String) throws -> [Int: Bool] {
			var out: [Int: Bool] = [:]
			for (key, value) in flags {
				guard let index = Int(key), (0..<count).contains(index) else {
					throw MachmanError(
						code: .notFound, message: "\(name) has no \(what) port \(key)")
				}
				out[index] = value
			}
			return out
		}
		let consoleByIndex = try parsed(consoleFlags, count: consolePorts.count, what: "console")
		let uartByIndex = try parsed(uartFlags, count: uartPorts.count, what: "UART")
		for i in disks.indices {
			if let value = diskFlags[disks[i].id] { disks[i].enabled = value }
		}
		for i in mountPoints.indices {
			if let value = mountFlags[mountPoints[i].id.uuidString] {
				mountPoints[i].enabled = value
			}
		}
		for (index, value) in consoleByIndex { consolePorts[index].enabled = value }
		for (index, value) in uartByIndex { uartPorts[index].enabled = value }
		for i in devices.indices {
			if let value = deviceFlags[devices[i].kind] { devices[i].enabled = value }
		}
		try saveVMConfig()
	}
}
