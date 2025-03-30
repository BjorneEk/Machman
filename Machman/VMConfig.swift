//
//  VMConfig.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-29.
//

import Foundation
import Virtualization

enum VMState: String, Codable {
	case running
	case stopped
}

class VMConfig: Codable, Identifiable {
	var name: String
	var memorySize: UInt64
	var cpuCount: Int
	var state: VMState = .stopped
	var lastRan: Foundation.Date?
	var created: Foundation.Date
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
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case memorySize
		case cpuCount
		case state
		case lastRan
		case created
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
		//try VMConfig.createNewVMDirectory(name: newName)
		let oldName = self.name
		let fileManager = FileManager.default
		//let oldDiskPath = diskImagePath()
		//let oldVMIdentifierPath = vmIdentifierPath()
		//let oldEFIPath = EFIVariableStorePath()

		self.name = newName
		try fileManager.moveItem(at: URL(fileURLWithPath: "\(machmanVMDir)/\(oldName)"), to: URL(fileURLWithPath: "\(machmanVMDir)/\(self.name)"))
		try saveVMConfig()
		//try VMConfig.deleteVMDirectory(name: oldName)
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



}
