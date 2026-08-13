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
	var sharesClipboard: Bool?

	var id: String { kind }
	var deviceKind: DeviceKind { DeviceKind(rawValue: kind) ?? .unknown }

	init(kind: DeviceKind) {
		self.kind = kind.rawValue
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case enabled
		case displayWidthPixels
		case displayHeightPixels
		case displayPixelsPerInch
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
		self.sharesClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharesClipboard)
	}
}

// A per-kernel-file command-line override (vm.kernel.setOverride). Persisted in VMConfig
// keyed by the file's VM-relative identity "role/tag/fileName" — stable across VM renames
// and library relocation, unlike the absolute path the wire uses to address files.
struct KernelOverrideConfig: Codable, Equatable {
	var commandLine: String
	var enabled: Bool
}

extension VMConfig {
	// The device set a config gets when its file predates the devices key — exactly what the
	// engine attached unconditionally before devices became configurable. Shared vocabulary
	// with clients via MachmanAPI.ImpliedDevices.
	static func impliedDevices(for boot: BootConfig) -> [GuestDevice] {
		let macGuest = if case .macOS = boot { true } else { false }
		return ImpliedDevices.kinds(macGuest: macGuest).map(GuestDevice.init)
	}

	// The wire addresses kernel overrides by absolute file path; the config keys them by the
	// stable VM-relative identity.
	static func kernelOverrideKey(for file: OwnedKernelFile) -> String {
		"\(file.role.rawValue)/\(file.tag)/\(file.fileName)"
	}

	// MARK: - Device mutations (vm.device.*)

	func addDevice(_ device: GuestDevice) throws {
		guard !devices.contains(where: { $0.kind == device.kind }) else {
			throw MachmanError(
				code: .alreadyExists, message: "\(name) already has a \(device.kind) device")
		}
		devices.append(device)
		try saveVMConfig()
	}

	func removeDevice(kind: DeviceKind) throws {
		guard devices.contains(where: { $0.deviceKind == kind }) else {
			throw MachmanError(
				code: .notFound, message: "no \(kind.rawValue) device on \(name)")
		}
		devices.removeAll { $0.deviceKind == kind }
		try saveVMConfig()
	}

	func updateDevice(_ updated: GuestDevice) throws {
		guard let index = devices.firstIndex(where: { $0.kind == updated.kind }) else {
			throw MachmanError(
				code: .notFound, message: "no \(updated.kind) device on \(name)")
		}
		devices[index] = updated
		try saveVMConfig()
	}

	// MARK: - Enabled flags (vm.setEnabled) — setSafety twin: all-or-nothing precheck.

	func setEnabled(
		disks diskFlags: [String: Bool], mounts mountFlags: [String: Bool],
		console consoleFlags: [String: Bool], uart uartFlags: [String: Bool]
	) throws {
		for id in diskFlags.keys where !disks.contains(where: { $0.id == id }) {
			throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
		}
		for id in mountFlags.keys
			where !mountPoints.contains(where: { $0.id.uuidString == id }) {
			throw MachmanError(code: .notFound, message: "no mount '\(id)' on \(name)")
		}
		// Serial ports arrive as string indices ("0", "1"…) — JSON-object keys on the wire.
		func parsed(_ flags: [String: Bool], count: Int, what: String) throws -> [Int: Bool] {
			var out: [Int: Bool] = [:]
			for (key, value) in flags {
				guard let index = Int(key), (0..<count).contains(index) else {
					throw MachmanError(
						code: .notFound, message: "no \(what) port \(key) on \(name)")
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
		try saveVMConfig()
	}

	// MARK: - Kernel overrides (vm.kernel.setOverride)

	// nil fields leave that half unchanged; the override entry persists even while disabled
	// so the text survives toggling.
	func setKernelOverride(forFileAt path: String, commandLine: String?, enabled: Bool?) throws {
		guard let file = ownedKernelFiles().first(where: { $0.path == path }) else {
			throw MachmanError(
				code: .notFound, message: "no owned kernel file at '\(path)' on \(name)")
		}
		let key = VMConfig.kernelOverrideKey(for: file)
		var override = kernelOverrides[key]
			?? KernelOverrideConfig(commandLine: "", enabled: false)
		if let commandLine { override.commandLine = commandLine }
		if let enabled { override.enabled = enabled }
		kernelOverrides[key] = override
		try saveVMConfig()
	}

	// Deleting an owned kernel file drops its override. The key is derivable from the path's
	// last three components (<kernelsDir>/<role>/<tag>/<fileName>).
	func pruneKernelOverride(forDeletedPath path: String) {
		let components = (path as NSString).pathComponents.suffix(3)
		guard components.count == 3 else { return }
		let key = components.joined(separator: "/")
		if kernelOverrides.removeValue(forKey: key) != nil {
			try? saveVMConfig()
		}
	}

	// MARK: - Disk resize (vm.disk.resize) — grow-only, owned storage only.

	func growStorageDisk(id: String, to newSize: UInt64) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
		}
		guard case .storage(let storageName, _) = disks[index].kind else {
			throw MachmanError(
				code: .invalidArgument, message: "only owned storage disks can be resized")
		}
		let path = configFilePath(file: "\(storageName).raw")
		let current = getDiskSize(disk: disks[index]) ?? 0
		guard newSize > current else {
			throw MachmanError(
				code: .invalidArgument,
				message: "resize can only grow (\(storageName).raw is already "
					+ "\(current) bytes)")
		}
		let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
		defer { try? handle.close() }
		try handle.truncate(atOffset: newSize)
		// Also refresh the persisted size so the config stops going stale.
		disks[index].kind = .storage(storageName, newSize)
		try saveVMConfig()
	}
}
