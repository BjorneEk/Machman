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

	// The system-key-capture mode a run starts with: the display device's default, off when
	// unset, unknown (a newer daemon's mode), or there is no display device at all.
	var systemKeyCaptureDefault: SystemKeyCapture {
		let mode = devices.first { $0.deviceKind == .graphics }?.systemKeyCaptureMode ?? .off
		return mode == .unknown ? .off : mode
	}

	// The wire addresses kernel overrides by absolute file path; the config keys them by the
	// stable VM-relative identity.
	static func kernelOverrideKey(for file: OwnedKernelFile) -> String {
		"\(file.role.rawValue)/\(file.tag)/\(file.fileName)"
	}

	// The same key read off an owned file's path: its last three components
	// (<kernelsDir>/<role>/<tag>/<fileName>). nil for a path too short to carry one.
	static func kernelOverrideKey(forPath path: String) -> String? {
		let components = (path as NSString).pathComponents.suffix(3)
		guard components.count == 3 else { return nil }
		return components.joined(separator: "/")
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

	// MARK: - Kernel overrides (vm.kernel.setOverride)

	// nil fields leave that half unchanged; the override entry persists even while disabled
	// so the text survives toggling.
	func setKernelOverride(forFileAt path: String, commandLine: String?, enabled: Bool?) throws {
		guard let file = ownedKernelFiles().first(where: { $0.path == path }) else {
			throw MachmanError(
				code: .notFound, message: "\(name) no longer has that kernel file")
		}
		let key = VMConfig.kernelOverrideKey(for: file)
		var override = kernelOverrides[key]
			?? KernelOverrideConfig(commandLine: "", enabled: false)
		if let commandLine { override.commandLine = commandLine }
		if let enabled { override.enabled = enabled }
		kernelOverrides[key] = override
		try saveVMConfig()
	}

	// Deleting an owned kernel file drops its override.
	func pruneKernelOverride(forDeletedPath path: String) {
		guard let key = VMConfig.kernelOverrideKey(forPath: path) else { return }
		if kernelOverrides.removeValue(forKey: key) != nil {
			try? saveVMConfig()
		}
	}

	// MARK: - Disk resize (vm.disk.resize) — grow-only, owned storage only.

	// Rename an owned storage disk: moves the backing file and rewrites the disk entry
	// (the disk's id is derived from the name, so callers re-resolve after this). A failed
	// save moves the file back (D22): the config on disk still names the old one.
	func renameStorageDisk(id: String, to newName: String) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		guard case .storage(let oldName, let size) = disks[index].kind else {
			throw MachmanError(
				code: .invalidArgument, message: "Only owned disks can be renamed")
		}
		let trimmed = try NameRule.diskName.normalized(newName)
		guard trimmed != oldName else { return }
		guard !disks.contains(where: { $0.id == "storage:\(trimmed)" }) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a disk named \u{201C}\(trimmed)\u{201D}")
		}
		let oldPath = configFilePath(file: "\(oldName).raw")
		let newPath = configFilePath(file: "\(trimmed).raw")
		// A change of letter case only finds the disk's own file on a case-insensitive
		// volume (D36): that is no other file, and the move renames it.
		guard !FileManager.default.fileExists(atPath: newPath) || isSameFile(oldPath, newPath)
		else {
			throw MachmanError(
				code: .alreadyExists,
				message: "A file named \u{201C}\(trimmed).raw\u{201D} is already in the "
					+ "VM’s folder")
		}
		try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
		disks[index].kind = .storage(trimmed, size)
		do {
			try saveVMConfig()
		} catch {
			disks[index].kind = .storage(oldName, size)
			do {
				try FileManager.default.moveItem(atPath: newPath, toPath: oldPath)
			} catch let moveBack {
				MachmanLogger.log(.passiveError,
					"\(name): \(trimmed).raw couldn’t move back to \(oldName).raw: \(moveBack)")
			}
			throw error
		}
	}

	// Change how a mount reaches the guest (1.0.7). Value/boot-mode validation is the
	// caller's (LocalMachman.validateMountKind — only it can name the error well).
	func setMountKind(id: String, kind: String) throws {
		guard let index = mountPoints.firstIndex(where: { $0.id.uuidString == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that mount")
		}
		guard mountPoints[index].kind != kind else { return }
		mountPoints[index].kind = kind
		try saveVMConfig()
	}

	// Change a mount's guest tag (what the guest passes to mount -t virtiofs).
	func setMountTag(id: String, tag: String) throws {
		guard let index = mountPoints.firstIndex(where: { $0.id.uuidString == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that mount")
		}
		let trimmed = try VMConfig.normalizedShareTag(tag)
		guard mountPoints[index].tag != trimmed else { return }
		guard !mountPoints.contains(where: { $0.tag == trimmed }) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a mount tagged \u{201C}\(trimmed)\u{201D}")
		}
		mountPoints[index].tag = trimmed
		try saveVMConfig()
	}

	// Re-tag an owned kernel/initramfs file: moves it on disk and migrates the kernel-boot
	// references and the per-file override to the new path/key. Returns the new path. A
	// failed save re-tags the file back (D22's shape: the config still names the old path).
	@discardableResult
	func renameKernelFile(path: String, to newTag: String) throws -> String {
		// KernelStore moves the standardized path, so every comparison here uses it too (a
		// wire path may carry "." or "..").
		let oldPath = URL(fileURLWithPath: path).standardized.path
		let newPath = try KernelStore.rename(
			path: path, kernelsDir: kernelsDirPath(), newTag: newTag)
		guard newPath != oldPath else { return newPath }
		let before = (kernelSettings, boot, kernelOverrides)
		func isOld(_ reference: String?) -> Bool {
			guard let reference, !reference.isEmpty else { return false }
			return URL(fileURLWithPath: reference).standardized.path == oldPath
		}
		if var settings = kernelSettings {
			var changed = false
			if isOld(settings.kernelPath) {
				settings.kernelPath = newPath
				changed = true
			}
			if isOld(settings.initialRamdiskPath) {
				settings.initialRamdiskPath = newPath
				changed = true
			}
			if changed { applyKernelSettings(settings) }
		}
		// The override follows the file to the key its NEW path names — KernelStore's
		// normalized tag, never one rebuilt from the raw text.
		if let oldKey = VMConfig.kernelOverrideKey(forPath: oldPath),
			let newKey = VMConfig.kernelOverrideKey(forPath: newPath),
			let value = kernelOverrides.removeValue(forKey: oldKey) {
			kernelOverrides[newKey] = value
		}
		do {
			try saveVMConfig()
		} catch {
			(kernelSettings, boot, kernelOverrides) = before
			let oldTag = URL(fileURLWithPath: oldPath).deletingLastPathComponent()
				.lastPathComponent
			do {
				_ = try KernelStore.rename(
					path: newPath, kernelsDir: kernelsDirPath(), newTag: oldTag)
			} catch let moveBack {
				MachmanLogger.log(.passiveError,
					"\(name): \(newPath) couldn’t move back to its tag \(oldTag): \(moveBack)")
			}
			throw error
		}
		return newPath
	}

	func growStorageDisk(id: String, to newSize: UInt64) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		guard case .storage(let storageName, _) = disks[index].kind else {
			throw MachmanError(
				code: .invalidArgument, message: "Only owned disks can grow")
		}
		let path = configFilePath(file: "\(storageName).raw")
		let current = getDiskSize(disk: disks[index]) ?? 0
		guard newSize > current else {
			throw MachmanError(
				code: .invalidArgument,
				message: "Disks only grow — enter more than \(ByteSize.display(current))")
		}
		try VMConfig.validateRawSize(newSize)
		let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
		defer { try? handle.close() }
		try handle.truncate(atOffset: newSize)
		// Also refresh the persisted size so the config stops going stale.
		disks[index].kind = .storage(storageName, newSize)
		try saveVMConfig()
	}
}
