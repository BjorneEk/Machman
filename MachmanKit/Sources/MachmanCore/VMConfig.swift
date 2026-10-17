//
//  VMConfig.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-29.
//
//  The persisted description of a VM (the on-disk `config` JSON) plus its file-path helpers.
//  Runtime state is NOT part of this: whether a VM is running is derived from its live
//  VMRuntime, never persisted. A legacy "state" key in old config files is ignored on load
//  and dropped on the next save.
//
//  Beside it: VMConfig+Disks, +Kernel and +Serial (the edits by area), GuestDevices (the device
//  list and enabled flags), and VMDevices (the VZ configuration built from a config).
//

import Foundation
import Virtualization
import MachmanAPI

enum VirtualMachineError: Error, LocalizedError {
	case critical(String)

	// The sentence itself, so every user-facing path (MachmanError.userMessage) shows it.
	var errorDescription: String? {
		switch self {
		case .critical(let message): return message
		}
	}
}

struct HostMountPoint: Codable, Identifiable {
	var id = UUID()
	var path: String
	var tag: String
	// Safe-mode policy (phase 6): true = a safe run omits this mount; false = attach it anyway.
	var safe: Bool = true
	// 1.0.4: disabled mounts stay configured but are not shared at the next start.
	var enabled: Bool = true
	// 1.0.7: how the mount reaches the guest — MountKind.virtiofs rides the share device,
	// MountKind.sshfs is mounted by the guest over its SSH link. Plain string on disk (the
	// GuestDevice.kind lesson): a newer daemon's value survives this one's load/save.
	var kind: String = MountKind.virtiofs

	// id must persist: removeMount matches on it, so a regenerated id breaks mount removal
	// after any daemon restart or registry reload.
	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		self.path = try container.decode(String.self, forKey: .path)
		// A hand-edited mount without a tag still loads (D38), tagged as the add flow tags a
		// new mount of that folder; tags are validated at entry, never at load.
		self.tag = try container.decodeIfPresent(String.self, forKey: .tag)
			?? NameRule.mountTag.suggestion(
				from: URL(fileURLWithPath: path).lastPathComponent, fallback: "share")
		self.safe = try container.decodeIfPresent(Bool.self, forKey: .safe) ?? true
		self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
			?? MountKind.virtiofs
	}

	init (path: String, tag: String, kind: String = MountKind.virtiofs) {
		self.path = path
		self.tag = tag
		self.kind = kind
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case path
		case tag
		case safe
		case enabled
		case kind
	}
}

// The old persisted disk enum, byte-identical on disk (positional {"storage":{"_0":…,"_1":…}}).
// NEVER add associated values to its known cases — their coding is the compiler's positional
// one (Known below), so any change silently breaks every config on disk. New per-disk fields
// go on VMDisk.
enum VMDiskKind: Equatable {
	case storage(String, UInt64)
	case fromUrl(URL)
	case iso(URL)
	// A disk entry a newer Machman wrote (D38), kept whole as read — BootConfig.unknown's
	// pattern: it lists, a save writes it back, and the VM doesn't start while it is enabled
	// (VMConfig.requireStartable). Only VMDisk's decoder makes one.
	case unknown(JSONValue)
}

extension VMDiskKind: Codable {
	// The three known shapes, coded by the compiler exactly as before .unknown existed.
	private enum Known: Codable {
		case storage(String, UInt64)
		case fromUrl(URL)
		case iso(URL)
	}

	init(from decoder: any Decoder) throws {
		switch try Known(from: decoder) {
		case .storage(let name, let size): self = .storage(name, size)
		case .fromUrl(let url): self = .fromUrl(url)
		case .iso(let url): self = .iso(url)
		}
	}

	func encode(to encoder: any Encoder) throws {
		switch self {
		case .storage(let name, let size): try Known.storage(name, size).encode(to: encoder)
		case .fromUrl(let url): try Known.fromUrl(url).encode(to: encoder)
		case .iso(let url): try Known.iso(url).encode(to: encoder)
		case .unknown(let entry): try entry.encode(to: encoder)
		}
	}
}

struct VMDisk: Codable, Identifiable, Equatable {
	var kind: VMDiskKind
	// Safe-mode policy (phase 6): true = a safe run clones this disk; false = attach the
	// real file.
	var safe: Bool = true
	// 1.0.4: disabled disks stay configured but are not attached at the next start.
	var enabled: Bool = true

	init(kind: VMDiskKind, safe: Bool = true) {
		self.kind = kind
		self.safe = safe
	}

	// The same entry pointing at another file. Every rebuild (a copy, a shadow, a promote)
	// goes through here, so the entry's flags — safe and enabled alike — always carry.
	func withKind(_ kind: VMDiskKind) -> VMDisk {
		var disk = self
		disk.kind = kind
		return disk
	}

	var id: String {
		switch kind {
		case .storage(let name, _): return "storage:\(name)"
		case .fromUrl(let url): return "url:\(url.absoluteString)"
		case .iso(let url): return "iso:\(url.absoluteString)"
		case .unknown(let entry): return "unknown:" + (entry["kind"] ?? entry).canonicalText
		}
	}

	// How a newer Machman's disk lists (D38): what it is, never its raw entry.
	static let newerKindName = "Disk from a newer Machman"

	// What refuses to start a VM while a newer Machman's disk is enabled (D38).
	static var newerKindRefusal: MachmanError {
		MachmanError(
			code: .invalidState,
			message: "A newer version of Machman added one of this VM’s disks — disable it to "
				+ "start without it")
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case safe
		case enabled
	}

	// Fallback decode: a keyed container WITH a "kind" key is the new shape; anything else is
	// the legacy bare enum, decoded directly (the legacy payload is also a keyed container —
	// its only key is the case name — so contains(.kind) is the discriminator). An entry
	// neither reads as is kept whole (D38): one disk this build doesn't know never hides the
	// VM. Encode is always-new: configs migrate on their next save.
	init(from decoder: any Decoder) throws {
		do {
			if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.kind) {
				self.kind = try c.decode(VMDiskKind.self, forKey: .kind)
				self.safe = (try? c.decodeIfPresent(Bool.self, forKey: .safe)) ?? true
				self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
			} else {
				self.kind = try VMDiskKind(from: decoder)
				self.safe = true
				self.enabled = true
			}
		} catch {
			let entry = try JSONValue(from: decoder)
			self.kind = .unknown(entry)
			self.safe = entry["safe"]?.boolValue ?? true
			self.enabled = entry["enabled"]?.boolValue ?? true
		}
	}

	func encode(to encoder: any Encoder) throws {
		if case .unknown(var entry) = kind {
			// As read, but with the flags this build can change (the inspector's toggles):
			// written where the entry has them or where they left the default.
			entry.setFlag("safe", safe, writing: entry["safe"] != nil || !safe)
			entry.setFlag("enabled", enabled, writing: entry["enabled"] != nil || !enabled)
			try entry.encode(to: encoder)
			return
		}
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(kind, forKey: .kind)
		try c.encode(safe, forKey: .safe)
		try c.encode(enabled, forKey: .enabled)
	}
}

// What VMDisk reads of an entry it keeps whole.
private extension JSONValue {
	subscript(key: String) -> JSONValue? {
		if case .object(let members) = self { return members[key] }
		return nil
	}

	var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	mutating func setFlag(_ key: String, _ value: Bool, writing: Bool) {
		guard writing, case .object(var members) = self else { return }
		members[key] = .bool(value)
		self = .object(members)
	}

	// Sorted keys: the same entry always yields the same text (a stable disk id).
	var canonicalText: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
	}
}

// A configured serial port. The only structural config is how many console/uart ports a VM has;
// each port additionally carries a logging config. The API's SerialLogConfig is persisted
// directly (like StartPolicy) so there is no mirror type to keep in lockstep.
struct SerialPort: Codable, Equatable {
	var logging: SerialLogConfig = SerialLogConfig()
	// 1.0.4: disabled ports stay configured but are not attached at the next start (guest
	// names renumber, same as removing the port).
	var enabled: Bool = true
	// 1.0.7: the device name the GUEST reported for this port (ttyV0.0, hvc0, …) — nil
	// until a setup run finds one. EFI proves no OS, so this is never guessed here.
	var guestName: String?

	init(logging: SerialLogConfig = SerialLogConfig()) {
		self.logging = logging
	}

	// Tolerant decode so a hand-written or future-shaped entry still loads with defaults.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.logging = try c.decodeIfPresent(SerialLogConfig.self, forKey: .logging)
			?? SerialLogConfig()
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		self.guestName = try c.decodeIfPresent(String.self, forKey: .guestName)
	}

	private enum CodingKeys: String, CodingKey {
		case logging
		case enabled
		case guestName
	}
}

class VMConfig: Codable, Identifiable, ObservableObject {
	var name: String
	var memorySize: UInt64
	var cpuCount: Int
	var lastRan: Foundation.Date?
	var created: Foundation.Date
	var disks: [VMDisk] = []
	var mountPoints: [HostMountPoint] = []
	var boot: BootConfig = .efi
	var macAddress: String?
	var kernelSettings: LinuxKernelBoot?
	// How this VM prefers to start (run-defaults UI, autostart, safe runs). The MachmanAPI DTO
	// is persisted directly — a mirror type would be one more lockstep site carrying nothing,
	// and StartPolicy is coder-agnostic (defaults-on-decode, no Dates).
	var startPolicy = StartPolicy()
	// Accumulated across sessions at teardown, in the process that ran the VM. A SIGKILLed
	// vmhost loses that session's runtime — accepted.
	var totalRuntimeSeconds: Double = 0
	// Serial ports, by family. Count = array length; each element carries its logging config.
	// Fixed at VM start by the framework, so add/remove is refused while the VM runs.
	var consolePorts: [SerialPort] = []
	var uartPorts: [SerialPort] = []
	// Guest devices (1.0.4). Configs predating the key get the implied per-boot set at load
	// (presence sentinel, like the serial ports); present-but-empty stays empty.
	var devices: [GuestDevice] = []
	// Nested virtualization (EFI/kernel boots on supporting hardware only).
	var nestedVirtualization: Bool = false
	// Per-kernel-file command-line overrides, keyed by "role/tag/fileName"
	// (VMConfig.kernelOverrideKey). Encoded only when non-empty.
	var kernelOverrides: [String: KernelOverrideConfig] = [:]
	// SSH autoconfiguration state (1.0.5). nil until first used; encoded only when present.
	var ssh: SSHConfig?
	// Guest-setup installer state (1.0.7). nil until first used; encoded only when present.
	var setup: GuestSetupConfig?

	init (name: String, memorySize: UInt64, cpuCount: Int) throws {
		self.name = name
		self.memorySize = memorySize
		self.cpuCount = cpuCount
		self.macAddress = VZMACAddress.randomLocallyAdministered().string
		self.created = Foundation.Date()
		self.lastRan = nil
		// A new VM boots EFI, so give it the one console every VM used to have by default.
		self.consolePorts = [SerialPort()]
		self.devices = VMConfig.impliedDevices(for: .efi)
		// A new VM takes a name: its default alias yields to every VM already there.
		assignDefaultAliasIfTaken()
		try saveVMConfig()
	}

	// Load a VM from <library>/<name>/config: a plain decode, then two invariants. The
	// DIRECTORY name is authoritative (renames move the directory; the file's name field is
	// discarded), and configs predating macAddress get one minted and saved there (one-time
	// migration). `library` is machmanVMDir unless the caller holds the folder's path (Save
	// as New VM's daemon half, a rewrite); the VM's other paths still resolve through
	// machmanVMDir, which names the same folder outside tests.
	static func load(name: String, library: String = machmanVMDir) throws -> VMConfig {
		let fileURL = URL(fileURLWithPath: "\(library)/\(name)/config")
		let data = try Data(contentsOf: fileURL)
		let config = try JSONDecoder().decode(VMConfig.self, from: data)
		config.name = name
		var needsSave = false
		if config.macAddress == nil {
			config.macAddress = VZMACAddress.randomLocallyAdministered().string
			needsSave = true
		}
		// Migration (1.0.7): the two legacy installer devices collapse into one guestSetup.
		if config.migrateLegacyInstallerDevices() {
			needsSave = true
		}
		// A config without a created date (D38) takes its folder's, once.
		if config.created == .distantPast {
			let folder = try? FileManager.default.attributesOfItem(atPath: "\(library)/\(name)")
			config.created = folder?[.creationDate] as? Foundation.Date ?? Foundation.Date()
			needsSave = true
		}
		if needsSave {
			try config.saveVMConfig(atDir: "\(library)/\(name)")
		}
		return config
	}

	// A config this process changes outside the registry — a safe run's history going back,
	// Save as New VM's hand-over and its rollback (Q39) — keeps every rule a registry VM's
	// does: it loads through load (the folder names the VM, the migrations run) and saves
	// through saveVMConfig at <dir>/config (a resolved alias suffix is stored). Names resolve
	// against machmanVMDir, which every caller points at dir's library.
	static func rewrite(atDir dir: String, _ change: (VMConfig) throws -> Void) throws {
		let folder = URL(fileURLWithPath: dir).standardizedFileURL
		let config = try load(
			name: folder.lastPathComponent, library: folder.deletingLastPathComponent().path)
		try change(config)
		try config.saveVMConfig(atDir: folder.path)
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case memorySize
		case cpuCount
		case lastRan
		case created
		case mountPoints
		case disks
		case boot
		case macAddress
		case kernelSettings
		case startPolicy
		case totalRuntimeSeconds
		case consolePorts
		case uartPorts
		case devices
		case nestedVirtualization
		case kernelOverrides
		case ssh
		case setup
	}

	// Explicit Codable so new fields can default when absent from older config files on disk.
	// Every persisted field appears in four places — its stored property, CodingKeys,
	// init(from:) and encode(to:) — keep all four in lockstep when adding a field.
	// (load(name:) is a plain decode and needs nothing.) A config without a name or a created
	// date still loads (D38): every reader names the VM after its folder, and load() fills a
	// missing date from the folder's.
	required init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
		self.memorySize = try c.decode(UInt64.self, forKey: .memorySize)
		self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
		self.created = try c.decodeIfPresent(Foundation.Date.self, forKey: .created)
			?? .distantPast
		self.lastRan = try c.decodeIfPresent(Foundation.Date.self, forKey: .lastRan)
		self.mountPoints = try c.decodeIfPresent([HostMountPoint].self, forKey: .mountPoints) ?? []
		self.disks = try c.decodeIfPresent([VMDisk].self, forKey: .disks) ?? []
		self.boot = try c.decodeIfPresent(BootConfig.self, forKey: .boot) ?? .efi
		self.macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
		self.kernelSettings = try c.decodeIfPresent(LinuxKernelBoot.self, forKey: .kernelSettings)
		self.startPolicy = try c.decodeIfPresent(StartPolicy.self, forKey: .startPolicy)
			?? StartPolicy()
		self.totalRuntimeSeconds =
			try c.decodeIfPresent(Double.self, forKey: .totalRuntimeSeconds) ?? 0
		let hadSerialKeys = c.contains(.consolePorts) || c.contains(.uartPorts)
		self.consolePorts = try c.decodeIfPresent([SerialPort].self, forKey: .consolePorts) ?? []
		self.uartPorts = try c.decodeIfPresent([SerialPort].self, forKey: .uartPorts) ?? []
		// Migration: a config predating serial ports keeps the one console it always had, for
		// efi/linux guests (macOS never had a serial console). A config already written by this
		// code has the keys present — even when empty — so an intentional zero stays zero.
		if !hadSerialKeys {
			switch boot {
			case .efi, .linuxKernel: self.consolePorts = [SerialPort()]
			case .macOS, .unknown: break   // a newer mode proves no console either
			}
		}
		// Migration (1.0.4): a config predating devices gets the implied per-boot set — what
		// the engine attached unconditionally before. Present-but-empty stays empty (a
		// deliberately device-less VM).
		if c.contains(.devices) {
			self.devices = try c.decode([GuestDevice].self, forKey: .devices)
		} else {
			self.devices = VMConfig.impliedDevices(for: boot)
		}
		self.nestedVirtualization =
			try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
		self.kernelOverrides = try c.decodeIfPresent(
			[String: KernelOverrideConfig].self, forKey: .kernelOverrides) ?? [:]
		self.ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh)
		self.setup = try c.decodeIfPresent(GuestSetupConfig.self, forKey: .setup)
	}

	func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(name, forKey: .name)
		try c.encode(memorySize, forKey: .memorySize)
		try c.encode(cpuCount, forKey: .cpuCount)
		try c.encodeIfPresent(lastRan, forKey: .lastRan)
		try c.encode(created, forKey: .created)
		try c.encode(mountPoints, forKey: .mountPoints)
		try c.encode(disks, forKey: .disks)
		try c.encode(boot, forKey: .boot)
		try c.encodeIfPresent(macAddress, forKey: .macAddress)
		try c.encodeIfPresent(kernelSettings, forKey: .kernelSettings)
		try c.encode(startPolicy, forKey: .startPolicy)
		try c.encode(totalRuntimeSeconds, forKey: .totalRuntimeSeconds)
		try c.encode(consolePorts, forKey: .consolePorts)
		try c.encode(uartPorts, forKey: .uartPorts)
		try c.encode(devices, forKey: .devices)
		try c.encode(nestedVirtualization, forKey: .nestedVirtualization)
		if !kernelOverrides.isEmpty {
			try c.encode(kernelOverrides, forKey: .kernelOverrides)
		}
		try c.encodeIfPresent(ssh, forKey: .ssh)
		try c.encodeIfPresent(setup, forKey: .setup)
	}

	func configFilePath(file: String) -> String {
		return "\(machmanVMDir)/\(self.name)/\(file)"
	}
	func localURL(file: String) -> URL {
		return URL(fileURLWithPath: configFilePath(file: file))
	}

	func vmIdentifierPath() -> String {
		return configFilePath(file: "vm_identifier")
	}

	func EFIVariableStorePath() -> String {
		return configFilePath(file: "efi_vars.fd")
	}

	func configPath() -> String {
		return configFilePath(file: "config")
	}

	func vmDirPath() -> String {
		"\(machmanVMDir)/\(self.name)"
	}

	// `dir`: the folder to save in, for a config loaded from an explicit library (load,
	// rewrite); else configPath()'s.
	func saveVMConfig(atDir dir: String? = nil) throws {
		persistResolvedDefaultAlias()
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		let path = dir.map { $0 + "/config" } ?? configPath()
		try Self.writeConfigFile(try encoder.encode(self), toPath: path)
	}

	// Every config file is written here. .atomic writes to a sibling temp file and renames:
	// without it a force quit or power loss mid-write leaves a truncated config, which the
	// registry scan cannot parse — and a VM that cannot be parsed disappears from the app. A
	// NEW config is owner-only (D40); the atomic replace keeps an existing file's mode, so a
	// VM made before keeps its own (K5).
	static func writeConfigFile(_ data: Data, toPath path: String) throws {
		let isNew = !FileManager.default.fileExists(atPath: path)
		try data.write(to: URL(fileURLWithPath: path), options: .atomic)
		if isNew, chmod(path, 0o600) != 0 {
			MachmanLogger.log(.passiveWarning,
				"couldn’t make \(path) owner-only: \(String(cString: strerror(errno)))")
		}
	}

	func markRan() throws {
		self.lastRan = Foundation.Date()
		try saveVMConfig()
	}

	// One session's runtime, added at teardown in the process that ran the VM. try? — the
	// teardown path must never throw.
	func addRuntime(_ seconds: TimeInterval) {
		guard seconds > 0 else { return }
		totalRuntimeSeconds += seconds
		try? saveVMConfig()
	}

	// One rule for every user-supplied share tag (add AND rename): the mount-tag rule
	// (trimmed; no "/", leading dot or control characters; none of VZ's refused characters;
	// never a reserved payload directory), then VZ's own share-name check, so VZ stays the
	// authority if it tightens. Not validateTag: that is the 36-byte rule for a DEVICE tag,
	// and mount tags are directory names inside one share.
	static func normalizedShareTag(_ raw: String) throws -> String {
		let tag = try NameRule.mountTag.normalized(raw)
		do {
			try VZMultipleDirectoryShare.validateName(tag)
		} catch {
			throw MachmanError(
				code: .invalidArgument,
				message: "\u{201C}\(tag)\u{201D} can’t name a shared folder")
		}
		return tag
	}

	func addMountPoint(_ mountPoint: HostMountPoint) throws {
		// Same rules as setMountTag — of mounts sharing a tag, only the first is shared
		// (directoryShareDeviceConfig).
		var mount = mountPoint
		mount.tag = try VMConfig.normalizedShareTag(mount.tag)
		guard !mountPoints.contains(where: { $0.tag == mount.tag }) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a mount tagged \u{201C}\(mount.tag)\u{201D}")
		}
		mountPoints.append(mount)
		try saveVMConfig()
	}
	func removeMountPoint(_ mountPoint: HostMountPoint) throws {
		guard let index = mountPoints.firstIndex(where: { $0.id == mountPoint.id }) else {
			return
		}
		mountPoints.remove(at: index)
		try saveVMConfig()
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

	static func computeMaxCPUCount() -> Int {
		let totalAvailableCPUs = ProcessInfo.processInfo.processorCount

		var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
		virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
		virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

		return virtualCPUCount
	}

	static func clampMemorySize(size: UInt64) -> UInt64 {
		return clampMemorySize(size: size, floor: 0)
	}

	// `floor` lets a boot mode raise the lower bound (macOS guests carry install-time minimums).
	static func clampMemorySize(size: UInt64, floor: UInt64) -> UInt64 {
		let lower = max(floor, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
		var realMemorySize = max(size, lower)
		realMemorySize = min(realMemorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
		return realMemorySize
	}

	// The VM library, owner-only when Machman makes it (D40): moved with MachmanDataDir to
	// /Users/Shared or another volume, nothing else keeps other accounts out of the guests'
	// disks. A library that exists keeps its mode (K5: only what is new is tightened).
	static func ensureLibrary() throws {
		try FileManager.default.createDirectory(
			atPath: machmanVMDir, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
	}

	// A new VM's folder, made exclusively and owner-only (D40): false when something already
	// has the name — a folder the registry skipped (its config didn't decode, and is still the
	// user's) or a stray file. Only the library itself is made on the way.
	@discardableResult
	static func createNewVMDirectory(name: String) throws -> Bool {
		try ensureLibrary()
		guard mkdir("\(machmanVMDir)/\(name)", 0o700) == 0 else {
			let code = errno
			if code == EEXIST { return false }
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t create the folder for \(name): "
					+ String(cString: strerror(code)))
		}
		return true
	}

	// The name changes only once the directory moved: a failed move (a stray directory at
	// the target) must leave the config saving where it lives. Name rules are the caller's
	// (VMRegistry.checkNewVMName).
	func rename(to newName: String) throws {
		let oldName = self.name
		let fileManager = FileManager.default
		let oldDir = "\(machmanVMDir)/\(oldName)"
		let newDir = "\(machmanVMDir)/\(newName)"
		do {
			try fileManager.moveItem(
				at: URL(fileURLWithPath: oldDir), to: URL(fileURLWithPath: newDir))
		} catch {
			if fileManager.fileExists(atPath: newDir) {
				throw MachmanError(
					code: .alreadyExists,
					message: "A VM named \u{201C}\(newName)\u{201D} already exists")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t rename \(oldName): \(MachmanError.userMessage(for: error))")
		}
		self.name = newName
		rewriteOwnedPaths(fromDir: oldDir, toDir: newDir, .moved)
		// A suffix assigned for the old name stood in for its default; the new name gets
		// its own default — yielding, like any VM taking a name. A chosen alias stays.
		if let alias = ssh?.alias, SSHAliasAssignment.isAssigned(alias, to: oldName) {
			dropAlias()
		}
		assignDefaultAliasIfTaken()
		try saveVMConfig()
	}

	// Applies per-id safety flags in one save. All-or-nothing: unknown ids refuse the whole
	// batch BEFORE any write, so a stale client id can't half-apply it.
	func setSafety(disks diskSafety: [String: Bool], mounts mountSafety: [String: Bool]) throws {
		for id in diskSafety.keys where !disks.contains(where: { $0.id == id }) {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		for id in mountSafety.keys
			where !mountPoints.contains(where: { $0.id.uuidString == id }) {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that mount")
		}
		for i in disks.indices {
			if let safe = diskSafety[disks[i].id] { disks[i].safe = safe }
		}
		for i in mountPoints.indices {
			if let safe = mountSafety[mountPoints[i].id.uuidString] { mountPoints[i].safe = safe }
		}
		try saveVMConfig()
	}

	func setStartPolicy(_ policy: StartPolicy) throws {
		startPolicy = policy
		try saveVMConfig()
	}

	func setCPUCount(_ newValue: Int) throws {
		self.cpuCount = newValue
		try saveVMConfig()
	}

	func setMemorySize(_ newValue: UInt64) throws {
		self.memorySize = newValue
		try saveVMConfig()
	}

	static func deleteVMDirectory(name: String) throws {
		try FileManager.default.removeItem(at: URL(fileURLWithPath: "\(machmanVMDir)/\(name)"))
	}

	// What a start actually gets: the configured values held to this host's bounds.
	var effectiveMemorySize: UInt64 {
		VMConfig.clampMemorySize(size: memorySize)
	}

	var effectiveCPUCount: Int {
		min(VMConfig.computeMaxCPUCount(), cpuCount)
	}

	// Mint and persist a fresh locally-administered MAC. The guest sees it on its next boot;
	// DHCP leases and MAC-keyed network rules tied to the old address stop matching.
	@discardableResult
	func regenerateMACAddress() throws -> String {
		let mac = VZMACAddress.randomLocallyAdministered().string
		macAddress = mac
		try saveVMConfig()
		return mac
	}
}
