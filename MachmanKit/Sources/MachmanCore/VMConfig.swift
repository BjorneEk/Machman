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

enum VirtualMachineError: Error {
	case critical(String)
}

struct HostMountPoint: Codable, Identifiable {
	var id = UUID()
	var path: String
	var tag: String
	// Safe-mode policy (phase 6): true = a safe run omits this mount; false = attach it anyway.
	var safe: Bool = true

	// id must persist: removeMount matches on it, so a regenerated id breaks mount removal
	// after any daemon restart or registry reload.
	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
		self.path = try container.decode(String.self, forKey: .path)
		self.tag = try container.decode(String.self, forKey: .tag)
		self.safe = try container.decodeIfPresent(Bool.self, forKey: .safe) ?? true
	}

	init (path: String, tag: String) {
		self.path = path
		self.tag = tag
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case path
		case tag
		case safe
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

	init(kind: VMDiskKind, safe: Bool = true) {
		self.kind = kind
		self.safe = safe
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
	}

	// Fallback decode: a keyed container WITH a "kind" key is the new shape; anything else is
	// the legacy bare enum, decoded directly (the legacy payload is also a keyed container —
	// its only key is the case name — so contains(.kind) is the discriminator). Encode is
	// always-new: configs migrate on their next save.
	init(from decoder: any Decoder) throws {
		if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.kind) {
			self.kind = try c.decode(VMDiskKind.self, forKey: .kind)
			self.safe = try c.decodeIfPresent(Bool.self, forKey: .safe) ?? true
		} else {
			self.kind = try VMDiskKind(from: decoder)
			self.safe = true
		}
	}

	func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(kind, forKey: .kind)
		try c.encode(safe, forKey: .safe)
	}
}

// A configured serial port. The only structural config is how many console/uart ports a VM has;
// each port additionally carries a logging config. The API's SerialLogConfig is persisted
// directly (like StartPolicy) so there is no mirror type to keep in lockstep.
struct SerialPort: Codable, Equatable {
	var logging: SerialLogConfig = SerialLogConfig()

	init(logging: SerialLogConfig = SerialLogConfig()) {
		self.logging = logging
	}

	// Tolerant decode so a hand-written or future-shaped entry still loads with defaults.
	init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.logging = try c.decodeIfPresent(SerialLogConfig.self, forKey: .logging)
			?? SerialLogConfig()
	}

	private enum CodingKeys: String, CodingKey {
		case logging
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
		try saveVMConfig()
	}

	// Load a VM from <machmanVMDir>/<name>/config: a plain decode, then two invariants. The
	// DIRECTORY name is authoritative (renames move the directory; the file's name field is
	// discarded), and configs predating macAddress get one minted and saved (one-time
	// migration).
	static func load(name: String) throws -> VMConfig {
		let fileURL = URL(fileURLWithPath: "\(machmanVMDir)/\(name)/config")
		let data = try Data(contentsOf: fileURL)
		let config = try JSONDecoder().decode(VMConfig.self, from: data)
		config.name = name
		if config.macAddress == nil {
			config.macAddress = VZMACAddress.randomLocallyAdministered().string
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
	}

	// Explicit Codable so new fields can default when absent from older config files on disk.
	// Every persisted field is enumerated in CodingKeys AND init(from:) AND encode(to:) —
	// keep all three in lockstep when adding a field. (load(name:) is a plain decode and
	// needs nothing.)
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
			case .macOS: break
			}
		}
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
	}

	func getDisks() -> [VMDisk] {
		self.disks
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

	func getDiskSize(disk: VMDisk) -> UInt64? {
		let url = switch disk.kind {
			case .fromUrl(let url):
				url
			case .storage(let name, _):
				localURL(file: "\(name).raw")
			case .iso(let url):
				url
		}
		do {
			let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
			if let fileSizeBytes = fileAttributes[.size] as? NSNumber {
				return UInt64(Double(truncating: fileSizeBytes))
			}
		} catch {
			return nil
		}
		return nil
	}

	// Removes the disk from the config; for .storage also deletes the backing image file.
	// Destructive — confirmation is the caller's job. Ownership = residency: storage raws
	// and isos living INSIDE the VM dir (imported/promoted) are deleted with their entry;
	// external files are only disconnected.
	func deleteDisk(disk: VMDisk) throws {
		self.disks.removeAll { $0 == disk }
		switch disk.kind {
		case .storage(let name, _):
			let url = localURL(file: "\(name).raw")
			if FileManager.default.fileExists(atPath: url.path) {
				try FileManager.default.removeItem(at: url)
			}
		case .iso(let url) where url.path.hasPrefix(vmDirPath() + "/"):
			if FileManager.default.fileExists(atPath: url.path) {
				try FileManager.default.removeItem(at: url)
			}
		default:
			break
		}
		try saveVMConfig()
	}

	// Swap a disk entry in place (vm.disk.promote): position and the caller-preserved safe
	// flag stay; only the kind changes.
	func replaceDisk(id: String, with newDisk: VMDisk) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
		}
		disks[index] = newDisk
		try saveVMConfig()
	}

	func vmDirPath() -> String {
		"\(machmanVMDir)/\(self.name)"
	}

	// .atomic writes to a sibling temp file and renames. Without it a force quit or power loss
	// mid-write leaves a truncated config, which the registry scan cannot parse — and a VM that
	// cannot be parsed silently disappears from the app.
	func saveVMConfig() throws {
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

	func addMountPoint(_ mountPoint: HostMountPoint) throws {
		mountPoints.append(mountPoint)
		try saveVMConfig()
	}
	func removeMountPoint(_ mountPoint: HostMountPoint) throws {
		guard let index = mountPoints.firstIndex(where: { $0.id == mountPoint.id }) else {
			return
		}
		mountPoints.remove(at: index)
		try saveVMConfig()
	}

	public func addDisk(disk: VMDisk) throws {
		disks.append(disk)
		try saveVMConfig()
	}

	public func addIsoDisk(isoUrl: URL) throws {
		try addDisk(disk: VMDisk(kind: .iso(isoUrl)))
	}

	public func addNewStorageDisk(name: String, size: UInt64) throws {
		let diskPath = self.configFilePath(file: "\(name).raw")
		let diskUrl = URL(fileURLWithPath: diskPath)
		let diskCreated = FileManager.default.createFile(
			atPath: diskPath,
			contents: nil,
			attributes: nil
		)
		if !diskCreated {
			throw VirtualMachineError.critical("Failed to create the main disk image: '\(diskPath)'")
		}

		guard let diskFileHandle = try? FileHandle(forWritingTo: diskUrl) else {
			throw VirtualMachineError.critical("Failed to get the file handle for the main disk image: '\(diskPath)'")
		}

		do {
			try diskFileHandle.truncate(atOffset: size)
		} catch {
			throw VirtualMachineError.critical("Failed to truncate the disk image: '\(diskPath)' (\(size))")
		}
		excludeFromBackup(path: diskPath)
		try addDisk(disk: VMDisk(kind: .storage(name, size)))
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

	static func fromGB(size: Int) -> UInt64 {
		return UInt64(size * 1024 * 1024 * 1024)
	}

	static func toGB(size: UInt64) -> Int {
		return Int(size / (1024 * 1024 * 1024))
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

	static func createNewVMDirectory(name: String) throws {
		let fileManager = FileManager.default
		let url = URL(fileURLWithPath: "\(machmanVMDir)/\(name)", isDirectory: true)
		try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
	}

	func rename(to newName: String) throws {
		let oldName = self.name
		let fileManager = FileManager.default

		self.name = newName
		try fileManager.moveItem(
			at: URL(fileURLWithPath: "\(machmanVMDir)/\(oldName)"),
			to: URL(fileURLWithPath: "\(machmanVMDir)/\(self.name)"))
		try saveVMConfig()
	}

	// Applies per-id safety flags in one save. All-or-nothing: unknown ids refuse the whole
	// batch BEFORE any write, so a stale client id can't half-apply it.
	func setSafety(disks diskSafety: [String: Bool], mounts mountSafety: [String: Bool]) throws {
		for id in diskSafety.keys where !disks.contains(where: { $0.id == id }) {
			throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
		}
		for id in mountSafety.keys
			where !mountPoints.contains(where: { $0.id.uuidString == id }) {
			throw MachmanError(code: .notFound, message: "no mount '\(id)' on \(name)")
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
				message: "a VM can have at most \(Self.maxSerialPorts) serial ports")
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
	}

	func setSerialLogging(kind: SerialPortKind, index: Int, config: SerialLogConfig) throws {
		switch kind {
		case .console:
			guard consolePorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "no console port \(index) on \(name)")
			}
			consolePorts[index].logging = config
		case .uart:
			guard uartPorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "no UART port \(index) on \(name)")
			}
			uartPorts[index].logging = config
		}
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
		kernelSettings = settings
		if isKernelBoot {
			boot = .linuxKernel(settings)
		}
		try saveVMConfig()
	}

	// Owned kernel/initramfs files (copies living under <vm>/kernels).
	func kernelsDirPath() -> String { configFilePath(file: "kernels") }
	func ownedKernelFiles() -> [OwnedKernelFile] {
		KernelStore.ownedFiles(
			kernelsDir: kernelsDirPath(),
			kernelPath: kernelSettings?.kernelPath,
			initrdPath: kernelSettings?.initialRamdiskPath)
	}

	// After deleting an owned kernel file, clear any kernel field that pointed at it.
	func clearKernelReference(to path: String) throws {
		guard var settings = kernelSettings else { return }
		var changed = false
		if settings.kernelPath == path { settings.kernelPath = ""; changed = true }
		if settings.initialRamdiskPath == path { settings.initialRamdiskPath = nil; changed = true }
		if changed {
			kernelSettings = settings
			if isKernelBoot { boot = .linuxKernel(settings) }
			try saveVMConfig()
		}
	}

	static func deleteVMDirectory(name: String) throws {
		try FileManager.default.removeItem(at: URL(fileURLWithPath: "\(machmanVMDir)/\(name)"))
	}

	func getMemorySize() -> UInt64 {
		return VMConfig.clampMemorySize(size: self.memorySize)
	}

	func getCPUCounte() -> Int {
		return min(VMConfig.computeMaxCPUCount(), self.cpuCount)
	}

	private func createVmIdentifier(_ vmIdentifierPath: String) throws -> VZGenericMachineIdentifier {
		let machineIdentifier = VZGenericMachineIdentifier()

		// Store the machine identifier to disk so you can retrieve it for subsequent boots.
		do {
			try machineIdentifier.dataRepresentation.write(
				to: URL(fileURLWithPath: vmIdentifierPath), options: .atomic)
		} catch {
			throw VirtualMachineError.critical(
				"Failed to store the machine identifier '\(vmIdentifierPath)': \(error)")
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
			throw VirtualMachineError.critical(
				"Failed to create the machine identifier: '\(vmIdentifierPath)'")
		}
		return machineIdentifier
	}

	private func createEFIVariableStore(_ efiVarsPath: String) throws -> VZEFIVariableStore {
		do {
			return try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVarsPath))
		} catch {
			throw VirtualMachineError.critical(
				"Failed to create the EFI variable store '\(efiVarsPath)': \(error)")
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
		guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: isoPath, readOnly: true) else {
			throw VirtualMachineError.critical("Failed to create iso disk: '\(isoPath)' attachment for: \(name)")
		}
		return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
	}

	func diskDeviceConfig(diskUrl: URL) throws -> VZVirtioBlockDeviceConfiguration {
		guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: diskUrl, readOnly: false) else {
			throw VirtualMachineError.critical("Failed to create disk: '\(diskUrl)' attachment for: \(name)")
		}

		let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
		return mainDisk
	}
	static func formatUrl(from url: URL, _ n: Int) -> String {
		let components = url.pathComponents.filter { $0 != "/" }

		guard n > 0 else { return "" }

		let lastComponents = components.suffix(n)
		return lastComponents.joined(separator: "/")
	}

	func diskArray() throws -> [VZStorageDeviceConfiguration] {
		return try disks.map {
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

	func directoryShareDeviceConfig(mainTag: String) -> VZVirtioFileSystemDeviceConfiguration {
		let sharedDirectories: [String: VZSharedDirectory] = Dictionary(
			uniqueKeysWithValues: mountPoints.map { mount in
				(mount.tag,
				VZSharedDirectory(url: URL(fileURLWithPath: mount.path), readOnly: false))
			}
		)
		let multipleDirectoryShare = VZMultipleDirectoryShare(directories: sharedDirectories)
		let sharingConfiguration = VZVirtioFileSystemDeviceConfiguration(tag: mainTag)
		sharingConfiguration.share = multipleDirectoryShare

		return sharingConfiguration
	}
}
