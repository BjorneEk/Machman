//
//  MacPlatform.swift
//  Machman
//
//  macOS-guest platform artifacts, persisted as sibling files next to the VM config (paralleling
//  vm_identifier / efi_vars.fd). Created during install (see MacInstaller); loaded on every boot.
//

import Foundation
import Virtualization

extension VMConfig {

	func macHardwareModelPath() -> String { configFilePath(file: "mac_hardware_model") }
	func macMachineIdPath() -> String { configFilePath(file: "mac_machine_id") }
	func macAuxStoragePath() -> String { configFilePath(file: "mac_aux.img") }

	// MARK: - Load (boot path)

	func getMacHardwareModel() throws -> VZMacHardwareModel {
		let path = macHardwareModelPath()
		guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
			let model = VZMacHardwareModel(dataRepresentation: data) else {
			throw VirtualMachineError.critical("Missing or invalid Mac hardware model: '\(path)'")
		}
		return model
	}

	func getMacMachineIdentifier() throws -> VZMacMachineIdentifier {
		let path = macMachineIdPath()
		guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
			let id = VZMacMachineIdentifier(dataRepresentation: data) else {
			throw VirtualMachineError.critical("Missing or invalid Mac machine identifier: '\(path)'")
		}
		return id
	}

	func getMacAuxiliaryStorage() throws -> VZMacAuxiliaryStorage {
		let path = macAuxStoragePath()
		guard FileManager.default.fileExists(atPath: path) else {
			throw VirtualMachineError.critical("Missing Mac auxiliary storage: '\(path)'")
		}
		return VZMacAuxiliaryStorage(url: URL(fileURLWithPath: path))
	}

	// MARK: - Create (install path)

	func persistMacHardwareModel(_ model: VZMacHardwareModel) throws {
		try model.dataRepresentation.write(to: URL(fileURLWithPath: macHardwareModelPath()))
	}

	@discardableResult
	func createMacMachineIdentifier() throws -> VZMacMachineIdentifier {
		let id = VZMacMachineIdentifier()
		try id.dataRepresentation.write(to: URL(fileURLWithPath: macMachineIdPath()))
		return id
	}

	@discardableResult
	func createMacAuxiliaryStorage(hardwareModel: VZMacHardwareModel) throws -> VZMacAuxiliaryStorage {
		return try VZMacAuxiliaryStorage(
			creatingStorageAt: URL(fileURLWithPath: macAuxStoragePath()),
			hardwareModel: hardwareModel,
			options: [])
	}

	// macOS needs a sizable system disk to restore onto; reuse an existing storage disk if present.
	func ensureMacSystemDisk(minimumSize: UInt64 = 64 * 1024 * 1024 * 1024) throws {
		let hasStorage = disks.contains { if case .storage = $0 { return true } else { return false } }
		if hasStorage { return }
		try addNewStorageDisk(name: "disk", size: minimumSize)
	}
}
