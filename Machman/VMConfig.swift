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

class VMConfig: Codable, Identifiable {
	var name: String
	var memorySize: UInt64
	var cpuCount: Int
	var state: VMState = .stopped
	var lastRan: Foundation.Date?
	var created: Foundation.Date
	var mountPoints: [HostMountPoint] = []
	weak var window: NSWindow?

	init (name: String, memorySize: UInt64, cpuCount: Int, diskSize: UInt64) throws {
		self.name = name
		self.memorySize = memorySize
		self.cpuCount = cpuCount
		created = Foundation.Date()
		createMainDiskImage(size: diskSize)
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
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case memorySize
		case cpuCount
		case state
		case lastRan
		case created
		case mountPoints
	}

	func configFilePath(file: String) -> String {
		return "\(machmanVMDir)/\(self.name)/\(file)"
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
	// Load a VMConfig object from the given URL.


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

	static func isoImageDeviceConfig(isoPath: URL) throws -> VZUSBMassStorageDeviceConfiguration {
		guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: isoPath, readOnly: true) else {
			throw VirtualMachineError.critical("Failed to create installer's disk attachment.")
		}
		return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
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

	func mainDiskDeviceConfig() throws -> VZVirtioBlockDeviceConfiguration {
		guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskImagePath()), readOnly: false) else {
			throw VirtualMachineError.critical("Failed to create main disk attachment for: \(name)")
		}

		let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
		return mainDisk
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
