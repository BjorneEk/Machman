//
//  VMConfig.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-29.
//

import Foundation
import Virtualization
import AppKit

enum VMState: String, Codable {
	case running
	case stopped
}

struct HostMountPoint: Codable, Identifiable {
	var id = UUID()
	var path: String
	var tag: String

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.path = try container.decode(String.self, forKey: .path)
		self.tag = try container.decode(String.self, forKey: .tag)
	}

	init (path: String, tag: String) {
		self.path = path
		self.tag = tag
	}

	private enum CodingKeys: String, CodingKey {
		case path
		case tag
	}
}

enum VMDisk: Codable, Identifiable, Equatable {
	case storage(String, UInt64)
	case fromUrl(URL)
	case iso(URL)
	var id: String {
		switch self {
		case .storage(let name, _): return "storage:\(name)"
		case .fromUrl(let url): return "url:\(url.absoluteString)"
		case .iso(let url): return "iso:\(url.absoluteString)"
		}
	}
}

class VMConfig: Codable, Identifiable, ObservableObject {
	var name: String
	var memorySize: UInt64
	var cpuCount: Int
	var state: VMState = .stopped
	var lastRan: Foundation.Date?
	var created: Foundation.Date
	var disks: [VMDisk] = []
	var mountPoints: [HostMountPoint] = []
	weak var window: NSWindow?

	init (name: String, memorySize: UInt64, cpuCount: Int, diskSize: UInt64) throws {
		self.name = name
		self.memorySize = memorySize
		self.cpuCount = cpuCount
		created = Foundation.Date()
		try self.addNewStorageDisk(name: "disk", size: diskSize)
		//createMainDiskImage(size: diskSize)
		try saveVMConfig()
	}

	init (name: String, memorySize: UInt64, cpuCount: Int) throws {
		self.name = name
		self.memorySize = memorySize
		self.cpuCount = cpuCount
		self.created = Foundation.Date()
		self.lastRan = nil
		try saveVMConfig()
	}

	init (name: String) throws {
		self.name = name
		let fileURL = URL(fileURLWithPath: "\(machmanVMDir)/\(self.name)/config")
		let data = try Data(contentsOf: fileURL)
		let decoder = JSONDecoder()
		let loadedConfig = try decoder.decode(VMConfig.self, from: data)
		self.memorySize = loadedConfig.memorySize
		self.cpuCount = loadedConfig.cpuCount
		self.created = loadedConfig.created
		self.lastRan = loadedConfig.lastRan
		self.mountPoints = loadedConfig.mountPoints
		self.disks = loadedConfig.disks
		//self.addDisk(disk: .storage(URL(fileURLWithPath: "\(machmanVMDir)/\(self.name)/disk.raw"), 0))
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case memorySize
		case cpuCount
		case state
		case lastRan
		case created
		case mountPoints
		case disks
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

	func diskImagePath() -> String {
		return configFilePath(file: "disk.raw")

	}

	func configPath() -> String {
		return configFilePath(file: "config")

	}
	func getDiskSize(disk: VMDisk) -> UInt64? {
		let url = switch disk {
			case .fromUrl(let url):
				url
			case .storage(let name, _):
				localURL(file: "\(name).raw")
			case .iso(let url):
				url
		}
		print(url.path)
		do {
			let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
			if let fileSizeBytes = fileAttributes[.size] as? NSNumber {
				//let sizeInGB = Double(truncating: fileSizeBytes) / 1_073_741_824 // 1024^3
				return UInt64(Double(truncating: fileSizeBytes))
			}
		} catch {
			return nil
		}
		return nil
	}
	func deleteDisk(disk: VMDisk) {
		self.disks.removeAll { $0 == disk }
		switch disk {
		case .storage(let name, _):
			let url = localURL(file: "\(name).raw")
			if VMListViewModel.confirmDialog(
				message: "Delete disk \(VMConfig.formatUrl(from: url, 2))?",
				informativeText: "\(name) remover do you wish to delete it?") {
				try! FileManager.default.removeItem(at: url)
			}
		default:
			break
		}
		try? saveVMConfig()

	}

	func saveVMConfig() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		let data = try encoder.encode(self)
		try data.write(to: URL(fileURLWithPath: configPath()))
	}

	func isRunning() -> Bool {
		return state == .running
	}

	func updateState(state: VMState) throws {
		self.state = state
		try saveVMConfig()
	}

	func addMountPoint(_ mountPoint: HostMountPoint) {
		mountPoints.append(mountPoint)
		try! saveVMConfig()
	}
	func removeMountPoint(_ mountPoint: HostMountPoint) {
		guard let index = mountPoints.firstIndex(where: { $0.id == mountPoint.id }) else {
			return
		}
		mountPoints.remove(at: index)
		try! saveVMConfig()
	}

	func start(window: NSWindow? = nil) throws {
		self.window = window
		self.lastRan = Foundation.Date()
		try updateState(state: .running)
	}

	func stop() throws {
		//if let window = window {
		window?.close()
		self.window = nil
		//}
		try updateState(state: .stopped)
	}
	public func addDisk(disk: VMDisk) {
		disks.append(disk)
		try! saveVMConfig()
	}
	// Load a VMConfig object from the given URL.
	public func addIsoDisk(isoUrl: URL) throws {
		addDisk(disk: .iso(isoUrl))
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
		addDisk(disk: .storage(name, size))
	}

	private func createMainDiskImage(size: UInt64) {
		let diskPath = diskImagePath()
		let diskCreated = FileManager.default.createFile(
			atPath: diskPath,
			contents: nil,
			attributes: nil
		)
		if !diskCreated {
			fatalError("Failed to create the main disk image: '\(diskPath)'")
		}

		guard let mainDiskFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: diskPath)) else {
			fatalError("Failed to get the file handle for the main disk image: '\(diskPath)'")
		}

		do {
			try mainDiskFileHandle.truncate(atOffset: size)
		} catch {
			fatalError("Failed to truncate the main disk image: '\(diskPath)'")
		}
	}

	static func computeMaxCPUCount() -> Int {
		let totalAvailableCPUs = ProcessInfo.processInfo.processorCount

		var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
		virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
		virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

		return virtualCPUCount
	}

	static func maxMemoryInGB() -> Int {
		return Int(Double(VZVirtualMachineConfiguration.maximumAllowedMemorySize) / 1024 * 1024 * 1024)
	}

	static func minMemoryInGB() -> Int {
		return Int(Double(VZVirtualMachineConfiguration.maximumAllowedMemorySize) / 1024 * 1024 * 1024)
	}

	static func fromGB(size: Int) -> UInt64 {
		return UInt64(size * 1024 * 1024 * 1024)
	}

	static func toGB(size: UInt64) -> Int {
		return Int(size / (1024 * 1024 * 1024))
	}

	static func clampMemorySize(size: UInt64) -> UInt64 {
		var realMemorySize = max(size, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
		realMemorySize = min(realMemorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
		return realMemorySize
	}

	static func createNewVMDirectory(name: String) throws {
		let fileManager = FileManager.default
		let url = URL(fileURLWithPath: "\(machmanVMDir)/\(name)", isDirectory: true)
		try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
	}

	func move(from old: String, to new: String) throws {
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: old) {
			try fileManager.moveItem(at: URL(fileURLWithPath: old), to: URL(fileURLWithPath: new))
		}
	}

	func rename(to newName: String) throws {
		let oldName = self.name
		let fileManager = FileManager.default

		self.name = newName
		try fileManager.moveItem(at: URL(fileURLWithPath: "\(machmanVMDir)/\(oldName)"), to: URL(fileURLWithPath: "\(machmanVMDir)/\(self.name)"))
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

	func getMemorySize() -> UInt64 {
		return VMConfig.clampMemorySize(size: self.memorySize)
	}

	func getCPUCounte() -> Int {
		return min(VMConfig.computeMaxCPUCount(), self.cpuCount)
	}

	private func createVmIdentifier(_ vmIdentifierPath: String) -> VZGenericMachineIdentifier {
		let machineIdentifier = VZGenericMachineIdentifier()

		// Store the machine identifier to disk so you can retrieve it for subsequent boots.
		try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmIdentifierPath))
		return machineIdentifier
	}

	func getVmIdentifier() -> VZGenericMachineIdentifier {
		let vmIdentifierPath = vmIdentifierPath()
		let fileURL = URL(fileURLWithPath: vmIdentifierPath)

		if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
			if let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) {
				return machineIdentifier
			} else {
				fatalError("Failed to create the machine identifier: '\(vmIdentifierPath)'")
			}
		} else {
			return createVmIdentifier(vmIdentifierPath)
		}
	}

	private func createEFIVariableStore(_ efiVarsPath: String) -> VZEFIVariableStore {
		guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVarsPath)) else {
			fatalError("Failed to create the EFI variable store: '\(efiVarsPath)'")
		}
		return efiVariableStore
	}

	func getEFIVariableStore() -> VZEFIVariableStore {
		let efiVarsPath = EFIVariableStorePath()
		if !FileManager.default.fileExists(atPath: efiVarsPath) {
			return createEFIVariableStore(efiVarsPath)
		}

		return VZEFIVariableStore(url: URL(fileURLWithPath: efiVarsPath))
	}



	static func networkDeviceConfig() -> VZVirtioNetworkDeviceConfiguration {
		let networkDevice = VZVirtioNetworkDeviceConfiguration()
		let natAttachment = VZNATNetworkDeviceAttachment()
		networkDevice.attachment = natAttachment
		return networkDevice
	}

	static func mainScreenSize(_ defaultWidth: Int, _ defaultHeight: Int) -> (width: Int, height: Int) {
		var width = defaultWidth
		var height = defaultHeight
		if let mainScreen = NSScreen.main {
			width = Int(mainScreen.frame.width)
			height = Int(mainScreen.frame.height)
		}
		return (width: width, height: height)
	}

	static func graphicsDeviceConfig() -> VZVirtioGraphicsDeviceConfiguration {
		let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
		let size = mainScreenSize(2560, 1440)
		graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: size.width, heightInPixels: size.height)]
		return graphicsDevice
	}

	static func inputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let inputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
		inputStream.source = VZHostAudioInputStreamSource()
		inputAudioDevice.streams = [inputStream]
		return inputAudioDevice
	}

	static func outputAudioDeviceConfig() -> VZVirtioSoundDeviceConfiguration {
		let outputAudioDevice = VZVirtioSoundDeviceConfiguration()
		let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
		outputStream.sink = VZHostAudioOutputStreamSink()
		outputAudioDevice.streams = [outputStream]
		return outputAudioDevice
	}

	static func spiceAgentConsoleDeviceConfig() -> VZVirtioConsoleDeviceConfiguration {
		let consoleDevice = VZVirtioConsoleDeviceConfiguration()

		let spiceAgentPort = VZVirtioConsolePortConfiguration()
		spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
		consoleDevice.ports[0] = spiceAgentPort

		return consoleDevice
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
			switch $0 {
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
