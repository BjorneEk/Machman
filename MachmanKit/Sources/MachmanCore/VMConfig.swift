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
		self.tag = try container.decode(String.self, forKey: .tag)
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
// NEVER add associated values to it — synthesized enum coding uses positional keys, so any
// change silently breaks every config on disk. New per-disk fields go on VMDisk.
enum VMDiskKind: Codable, Equatable {
	case storage(String, UInt64)
	case fromUrl(URL)
	case iso(URL)
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
		}
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case safe
		case enabled
	}

	// Fallback decode: a keyed container WITH a "kind" key is the new shape; anything else is
	// the legacy bare enum, decoded directly (the legacy payload is also a keyed container —
	// its only key is the case name — so contains(.kind) is the discriminator). Encode is
	// always-new: configs migrate on their next save.
	init(from decoder: any Decoder) throws {
		if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.kind) {
			self.kind = try c.decode(VMDiskKind.self, forKey: .kind)
			self.safe = try c.decodeIfPresent(Bool.self, forKey: .safe) ?? true
			self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
		} else {
			self.kind = try VMDiskKind(from: decoder)
			self.safe = true
			self.enabled = true
		}
	}

	func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(kind, forKey: .kind)
		try c.encode(safe, forKey: .safe)
		try c.encode(enabled, forKey: .enabled)
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

	// The framework caps a VM at 10 virtio serial-port devices; console + uart share that budget.
	static let maxSerialPorts = 10

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
	// discarded), and configs predating macAddress get one minted and saved (one-time
	// migration). `library` is machmanVMDir unless the caller holds the folder's path (Save
	// as New VM's daemon half); the VM's own paths, that save's among them, still resolve
	// through machmanVMDir, which names the same folder outside tests.
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
		if needsSave {
			try config.saveVMConfig()
		}
		return config
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
	// (load(name:) is a plain decode and needs nothing.)
	required init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.name = try c.decode(String.self, forKey: .name)
		self.memorySize = try c.decode(UInt64.self, forKey: .memorySize)
		self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
		self.created = try c.decode(Foundation.Date.self, forKey: .created)
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

	// The backing file's size, through a link when the entry names one (D23).
	func getDiskSize(disk: VMDisk) -> UInt64? {
		let url = switch disk.kind {
			case .fromUrl(let url):
				url
			case .storage(let name, _):
				localURL(file: "\(name).raw")
			case .iso(let url):
				url
		}
		return fileSize(atPath: url.path)
	}

	// Removes the disk from the config; for .storage also deletes the backing image file.
	// Destructive — confirmation is the caller's job. Ownership = residency: storage raws
	// and isos living INSIDE the VM dir (imported/promoted) are deleted with their entry;
	// external files are only disconnected. The config saves first (D22): a failed save
	// keeps the entry and its file. Once it saved, the disk IS removed — an owned file that
	// won't delete stays behind as an orphan, returned for the caller to report, never
	// thrown (review F3: the removal happened).
	@discardableResult
	func deleteDisk(disk: VMDisk) throws -> String? {
		let before = disks
		disks.removeAll { $0 == disk }
		do {
			try saveVMConfig()
		} catch {
			disks = before
			throw error
		}
		guard let file = ownedFile(of: disk), FileManager.default.fileExists(atPath: file)
		else { return nil }
		do {
			try FileManager.default.removeItem(atPath: file)
			return nil
		} catch {
			MachmanLogger.log(.passiveError,
				"\(name): removed the disk, but \(file) couldn’t be deleted: \(error)")
			return file
		}
	}

	// Swap a disk entry in place (vm.disk.promote): position and the entry's flags (safe,
	// enabled) stay; only the kind changes.
	func replaceDisk(id: String, kind: VMDiskKind) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		disks[index] = disks[index].withKind(kind)
		try saveVMConfig()
	}

	func vmDirPath() -> String {
		"\(machmanVMDir)/\(self.name)"
	}

	// .atomic writes to a sibling temp file and renames. Without it a force quit or power loss
	// mid-write leaves a truncated config, which the registry scan cannot parse — and a VM that
	// cannot be parsed silently disappears from the app.
	func saveVMConfig() throws {
		persistResolvedDefaultAlias()
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		let data = try encoder.encode(self)
		try data.write(to: URL(fileURLWithPath: configPath()), options: .atomic)
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

	// One entry per file (D34): a second entry for a file the VM already attaches shares the
	// first one's id, so neither can be addressed alone (removing one removed both), and a
	// start attached the file twice, writable, past the shared-disk guard's per-file sets.
	public func addDisk(disk: VMDisk) throws {
		let file = attachedFile(of: disk)
		if disks.contains(where: { Self.sameFile(attachedFile(of: $0), file) }) {
			throw MachmanError(
				code: .alreadyExists,
				message: "\(name) already uses “\((file as NSString).lastPathComponent)”")
		}
		disks.append(disk)
		try saveVMConfig()
	}

	public func addIsoDisk(isoUrl: URL) throws {
		try addDisk(disk: VMDisk(kind: .iso(isoUrl)))
	}

	// A new owned image, <name>.raw. The name follows the disk-name rule and must be new to
	// this VM — in its config and in its folder: creating over an existing file would wipe
	// that disk, even under a running VM (D15).
	public func addNewStorageDisk(name raw: String, size: UInt64) throws {
		let name = try NameRule.diskName.normalized(raw)
		try Self.validateRawSize(size)
		let taken = disks.contains {
			if case .storage(let existing, _) = $0.kind { return existing == name }
			return false
		}
		guard !taken else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a disk named \u{201C}\(name)\u{201D}")
		}
		let path = configFilePath(file: "\(name).raw")
		try Self.createDiskImage(atPath: path, size: size, name: name)
		excludeFromBackup(path: path)
		do {
			try addDisk(disk: VMDisk(kind: .storage(name, size)))
		} catch {
			disks.removeAll { $0.id == "storage:\(name)" }
			try? FileManager.default.removeItem(atPath: path)
			throw error
		}
	}

	// One size rule for every raw this engine sizes, new or grown (D24): VZ attaches raw
	// images in whole 512-byte sectors only — anything else fails the next start with
	// "Couldn’t attach x.raw" — and ftruncate takes an off_t.
	static func validateRawSize(_ size: UInt64) throws {
		guard size > 0, size % 512 == 0, size <= UInt64(Int64.max) else {
			throw MachmanError(
				code: .invalidArgument,
				message: "A disk’s size must be a positive multiple of 512 bytes")
		}
	}

	// O_EXCL: the image is created or the call fails — an existing file is never replaced.
	// Sparse: ftruncate allocates nothing.
	static func createDiskImage(atPath path: String, size: UInt64, name: String) throws {
		let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
		guard fd >= 0 else {
			let code = errno
			if code == EEXIST {
				throw MachmanError(
					code: .alreadyExists,
					message: "A file named \u{201C}\(name).raw\u{201D} is already in the "
						+ "VM’s folder")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t create \(name).raw: \(String(cString: strerror(code)))")
		}
		defer { close(fd) }
		guard ftruncate(fd, off_t(size)) == 0 else {
			let code = errno
			unlink(path)
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t size \(name).raw: \(String(cString: strerror(code)))")
		}
	}

	// Keep VM disks out of Time Machine. Only images the VM owns are touched: a .fromUrl or .iso
	// disk belongs to the user, who may well want it backed up.
	func excludeDiskImagesFromBackup() {
		for disk in disks {
			guard case .storage(let name, _) = disk.kind else { continue }
			excludeFromBackup(path: configFilePath(file: "\(name).raw"))
		}
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

	// A new VM's folder, made exclusively: false when something already has the name — a
	// folder the registry skipped (its config didn't decode, and is still the user's) or a
	// stray file. Only the library itself is made on the way.
	@discardableResult
	static func createNewVMDirectory(name: String) throws -> Bool {
		try FileManager.default.createDirectory(
			atPath: machmanVMDir, withIntermediateDirectories: true, attributes: nil)
		guard mkdir("\(machmanVMDir)/\(name)", 0o755) == 0 else {
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

	// MARK: - Serial ports (console + uart)

	private func ensureSerialCapacity() throws {
		guard consolePorts.count + uartPorts.count < Self.maxSerialPorts else {
			throw MachmanError(
				code: .invalidArgument,
				message: "A VM can have at most \(Self.maxSerialPorts) serial ports")
		}
	}

	func addConsolePort() throws {
		try ensureSerialCapacity()
		consolePorts.append(SerialPort())
		try saveVMConfig()
	}

	func removeLastConsolePort() throws {
		guard !consolePorts.isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no console ports")
		}
		consolePorts.removeLast()
		try saveVMConfig()
		removeSerialLog(kind: .console, index: consolePorts.count)
	}

	func addUartPort() throws {
		try ensureSerialCapacity()
		uartPorts.append(SerialPort())
		try saveVMConfig()
	}

	func removeLastUartPort() throws {
		guard !uartPorts.isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no UART ports")
		}
		uartPorts.removeLast()
		try saveVMConfig()
		removeSerialLog(kind: .uart, index: uartPorts.count)
	}

	// The per-port log file, derived one way for every consumer: the bridge writes it, the
	// registry reports it, and port removal deletes it.
	func serialLogURL(kind: SerialPortKind, index: Int) -> URL {
		localURL(file: "serial-\(kind.rawValue)\(index).log")
	}

	// Ports only remove from the end, so the dropped index is exactly the new count — its
	// log dies with it, and a port added later at the same index starts fresh. Best-effort:
	// removal happens while the VM is stopped (add/remove refuse while hosted), so nothing
	// holds the file open, but a failed unlink must not fail the config edit.
	private func removeSerialLog(kind: SerialPortKind, index: Int) {
		try? FileManager.default.removeItem(at: serialLogURL(kind: kind, index: index))
	}

	// The largest serial log cap vm.serial.setLogging accepts (E23): a trim reads up to twice the
	// cap into the vmhost's memory, and a cap of 2^63 or more overflowed the bridge. 0 and nil
	// both mean no cap.
	static let serialLogMaxBytesLimit: UInt64 = 1 << 30

	func setSerialLogging(kind: SerialPortKind, index: Int, config: SerialLogConfig) throws {
		let ports: ReferenceWritableKeyPath<VMConfig, [SerialPort]>
		switch kind {
		case .console:
			guard consolePorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "\(name) has no console port \(index)")
			}
			ports = \.consolePorts
		case .uart:
			guard uartPorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "\(name) has no UART port \(index)")
			}
			ports = \.uartPorts
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "Unknown serial port kind")
		}
		// Checked as a cap enters: a larger one the port already holds (written by a script)
		// keeps working, and clients send it back unchanged with every other logging edit.
		if let cap = config.maxBytes, cap > Self.serialLogMaxBytesLimit,
			cap != self[keyPath: ports][index].logging.maxBytes {
			throw MachmanError(
				code: .invalidArgument,
				message: "A serial log can be capped at 1 GB at most")
		}
		self[keyPath: ports][index].logging = config
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

	var isKernelBoot: Bool {
		if case .linuxKernel = boot { return true }
		return false
	}

	// The kernel-boot checkbox: on -> boot from the persisted kernel draft, off -> EFI.
	// The draft (`kernelSettings`) survives toggling off so the fields keep their values.
	func setKernelBoot(enabled: Bool) throws {
		let settings = kernelSettings
			?? LinuxKernelBoot(kernelPath: "", initialRamdiskPath: nil, commandLine: "")
		let newBoot: BootConfig = enabled ? .linuxKernel(settings) : .efi
		try BootConfig.validateTransition(from: boot, to: newBoot)
		if enabled {
			kernelSettings = settings
		}
		boot = newBoot
		try saveVMConfig()
	}

	// Writes the draft and, when kernel boot is active, keeps the live payload in sync.
	func updateKernelSettings(_ settings: LinuxKernelBoot) throws {
		applyKernelSettings(settings)
		try saveVMConfig()
	}

	// The one way kernel settings change (D21): the draft, and the live boot payload while
	// kernel boot is on — a start reads boot (makeBootLoader), so an edit that missed it
	// would boot the old files. No save; callers batch it into theirs.
	func applyKernelSettings(_ settings: LinuxKernelBoot) {
		kernelSettings = settings
		if isKernelBoot { boot = .linuxKernel(settings) }
	}

	// Owned kernel/initramfs files (copies living under <vm>/kernels).
	func kernelsDirPath() -> String { configFilePath(file: "kernels") }
	func ownedKernelFiles() -> [OwnedKernelFile] {
		KernelStore.ownedFiles(
			kernelsDir: kernelsDirPath(),
			kernelPath: kernelSettings?.kernelPath,
			initrdPath: kernelSettings?.initialRamdiskPath)
	}

	// The command line a kernel boot reads (D28): the active kernel file's own override while
	// it is on, else the VM's. The one rule for the boot and for any effective line served.
	func effectiveKernelCommandLine(for boot: LinuxKernelBoot) -> String {
		guard let file = ownedKernelFiles().first(where: {
			$0.role == .kernel && $0.path == boot.kernelPath
		}), let override = kernelOverrides[Self.kernelOverrideKey(for: file)], override.enabled
		else { return boot.commandLine }
		return override.commandLine
	}

	// How the VM directory changed: moved (rename, promotion — the files are now only at
	// the new place) or copied (vm.copy, safe-run shadowing — the source keeps its files).
	enum OwnedPathChange {
		case moved
		case copied
	}

	// Owned paths are absolute and embed the VM directory, so every operation that moves or
	// copies that directory must re-point them, or the config keeps using the old location's
	// files (C1, C12): the kernel and initramfs, owned (imported) isos, and — on a move only —
	// fromUrl entries naming a file inside the folder. A copy keeps its fromUrl references on
	// the source's files: that is VMCopier's reference rule, and a safe-run shadow's unsafe
	// disks MUST keep naming the real files. External paths (never under the old directory)
	// stay put. Mounts are never touched. No save — callers batch it into theirs.
	func rewriteOwnedPaths(
		fromDir oldDir: String, toDir newDir: String, _ change: OwnedPathChange
	) {
		func moved(_ path: String?) -> String? {
			guard let path, path.hasPrefix(oldDir + "/") else { return nil }
			return newDir + String(path.dropFirst(oldDir.count))
		}
		for index in disks.indices {
			switch disks[index].kind {
			case .iso(let url):
				if let path = moved(url.path) {
					disks[index].kind = .iso(URL(fileURLWithPath: path))   // flags stay
				}
			case .fromUrl(let url) where change == .moved:
				if let path = moved(url.path) {
					disks[index].kind = .fromUrl(URL(fileURLWithPath: path))
				}
			case .storage, .fromUrl:
				break
			}
		}
		guard var settings = kernelSettings else { return }
		var changed = false
		if let path = moved(settings.kernelPath) {
			settings.kernelPath = path
			changed = true
		}
		if let path = moved(settings.initialRamdiskPath) {
			settings.initialRamdiskPath = path
			changed = true
		}
		guard changed else { return }
		applyKernelSettings(settings)
	}

	// After deleting an owned kernel file, clear any kernel field that pointed at it.
	func clearKernelReference(to path: String) throws {
		guard var settings = kernelSettings else { return }
		var changed = false
		if settings.kernelPath == path { settings.kernelPath = ""; changed = true }
		if settings.initialRamdiskPath == path { settings.initialRamdiskPath = nil; changed = true }
		if changed {
			applyKernelSettings(settings)
			try saveVMConfig()
		}
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

	private func createVmIdentifier(_ vmIdentifierPath: String) throws -> VZGenericMachineIdentifier {
		let machineIdentifier = VZGenericMachineIdentifier()

		// Store the machine identifier to disk so you can retrieve it for subsequent boots.
		do {
			try machineIdentifier.dataRepresentation.write(
				to: URL(fileURLWithPath: vmIdentifierPath), options: .atomic)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t save \(name)’s machine identifier: "
					+ MachmanError.userMessage(for: error))
		}
		return machineIdentifier
	}

	func getVmIdentifier() throws -> VZGenericMachineIdentifier {
		let vmIdentifierPath = vmIdentifierPath()
		let fileURL = URL(fileURLWithPath: vmIdentifierPath)

		guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
			return try createVmIdentifier(vmIdentifierPath)
		}
		guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
			throw VirtualMachineError.critical("\(name)’s machine identifier can’t be read")
		}
		return machineIdentifier
	}

	private func createEFIVariableStore(_ efiVarsPath: String) throws -> VZEFIVariableStore {
		do {
			return try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVarsPath))
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t create \(name)’s EFI variable store: "
					+ MachmanError.userMessage(for: error))
		}
	}

	func getEFIVariableStore() throws -> VZEFIVariableStore {
		let efiVarsPath = EFIVariableStorePath()
		if !FileManager.default.fileExists(atPath: efiVarsPath) {
			return try createEFIVariableStore(efiVarsPath)
		}

		return VZEFIVariableStore(url: URL(fileURLWithPath: efiVarsPath))
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

	func getOrCreateMACAddress() -> VZMACAddress {
		if let s = macAddress, let mac = VZMACAddress(string: s) {
			return mac
		}
		let mac = VZMACAddress.randomLocallyAdministered()
		self.macAddress = mac.string
		try? saveVMConfig()
		return mac
	}

	func isoImageDeviceConfig(isoPath: URL) throws -> VZUSBMassStorageDeviceConfiguration {
		let attachment: VZDiskImageStorageDeviceAttachment
		do {
			attachment = try VZDiskImageStorageDeviceAttachment(url: isoPath, readOnly: true)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t attach \(isoPath.lastPathComponent): "
					+ MachmanError.userMessage(for: error))
		}
		return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
	}

	func diskDeviceConfig(diskUrl: URL) throws -> VZVirtioBlockDeviceConfiguration {
		let attachment: VZDiskImageStorageDeviceAttachment
		do {
			attachment = try VZDiskImageStorageDeviceAttachment(url: diskUrl, readOnly: false)
		} catch {
			throw VirtualMachineError.critical(
				"Couldn’t attach \(diskUrl.lastPathComponent): "
					+ MachmanError.userMessage(for: error))
		}
		return VZVirtioBlockDeviceConfiguration(attachment: attachment)
	}

	// Disabled entries (1.0.4) stay configured but are not attached.
	func diskArray() throws -> [VZStorageDeviceConfiguration] {
		return try disks.filter(\.enabled).map {
			switch $0.kind {
			case .iso(let url):
				return try self.isoImageDeviceConfig(isoPath: url)
			case .storage(let name, _):
				return try self.diskDeviceConfig(diskUrl: self.localURL(file: "\(name).raw"))
			case .fromUrl(let url):
				return try self.diskDeviceConfig(diskUrl: url)
			}
		}
	}

	// The mounts that ride the share device: the enabled virtiofs ones. sshfs-kind mounts
	// (1.0.7) never enter the share — the guest mounts them itself over its SSH link (the
	// payload's mounts.list carries them there instead).
	var sharedMounts: [HostMountPoint] {
		mountPoints.filter { $0.enabled && $0.kind != MountKind.sshfs }
	}

	func directoryShareDeviceConfig(
		mainTag: String, extraDirectories: [String: VZSharedDirectory] = [:]
	) -> VZVirtioFileSystemDeviceConfiguration {
		// A doubled tag shares its first mount (D25): add and rename refuse doubles, but a
		// config from before that, or edited by hand, still loads (names are validated at
		// entry, never at load) — and a trap here killed the vmhost at every start.
		// shareTagWarnings tells the user.
		var sharedDirectories: [String: VZSharedDirectory] = Dictionary(
			sharedMounts.map { mount in
				(mount.tag,
				VZSharedDirectory(url: URL(fileURLWithPath: mount.path), readOnly: false))
			},
			uniquingKeysWith: { first, _ in first })
		// Engine-reserved directories (the guest setup payload and its report drop-box).
		// Mount validation refuses their names, so the merge cannot shadow a user mount.
		sharedDirectories.merge(extraDirectories) { _, extra in extra }
		let multipleDirectoryShare = VZMultipleDirectoryShare(directories: sharedDirectories)
		let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: mainTag)
		sharingConfiguration.share = multipleDirectoryShare

		return sharingConfiguration
	}
}
