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
			throw VirtualMachineError.critical("Missing or invalid Mac hardware model: \(path)")
		}
		return model
	}

	func getMacMachineIdentifier() throws -> VZMacMachineIdentifier {
		let path = macMachineIdPath()
		guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
			let id = VZMacMachineIdentifier(dataRepresentation: data) else {
			throw VirtualMachineError.critical("Missing or invalid Mac machine identifier: \(path)")
		}
		return id
	}

	func getMacAuxiliaryStorage() throws -> VZMacAuxiliaryStorage {
		let path = macAuxStoragePath()
		guard FileManager.default.fileExists(atPath: path) else {
			throw VirtualMachineError.critical("Missing Mac auxiliary storage: \(path)")
		}
		return VZMacAuxiliaryStorage(url: URL(fileURLWithPath: path))
	}

	// MARK: - Create (install path)

	func persistMacHardwareModel(_ model: VZMacHardwareModel) throws {
		try model.dataRepresentation.write(
			to: URL(fileURLWithPath: macHardwareModelPath()), options: .atomic)
	}

	@discardableResult
	func createMacMachineIdentifier() throws -> VZMacMachineIdentifier {
		let id = VZMacMachineIdentifier()
		try id.dataRepresentation.write(
			to: URL(fileURLWithPath: macMachineIdPath()), options: .atomic)
		return id
	}

	// Mint a fresh machine identifier at an explicit path — VMCopier writes into staging
	// directories outside machmanVMDir, where the instance helpers can't point. The id is
	// installer-created otherwise, never lazily recreated, so a copy must mint its own.
	static func mintMacMachineIdentifier(at path: String) throws {
		try VZMacMachineIdentifier().dataRepresentation
			.write(to: URL(fileURLWithPath: path), options: .atomic)
	}

	// Created before VZMacOSInstaller runs, so a failed or cancelled install leaves it
	// behind and the retry creates it again (E24): it overwrites — the install rewrites the
	// platform identity beside it anyway (hardware model, machine id). MacInstaller refuses
	// an installed Mac, so this never replaces a working guest's NVRAM.
	static let macAuxStorageCreationOptions: VZMacAuxiliaryStorage.InitializationOptions =
		[.allowOverwrite]

	@discardableResult
	func createMacAuxiliaryStorage(hardwareModel: VZMacHardwareModel) throws -> VZMacAuxiliaryStorage {
		return try VZMacAuxiliaryStorage(
			creatingStorageAt: URL(fileURLWithPath: macAuxStoragePath()),
			hardwareModel: hardwareModel,
			options: Self.macAuxStorageCreationOptions)
	}

	// macOS needs a sizable system disk to restore onto; reuse an existing storage disk if
	// present. Otherwise "disk", or "disk-2", "disk-3"… when an orphan image (a .raw no
	// config entry names) already holds the name — creation never replaces a file.
	func ensureMacSystemDisk(minimumSize: UInt64 = 64 * 1024 * 1024 * 1024) throws {
		let hasStorage = disks.contains {
			if case .storage = $0.kind { return true } else { return false }
		}
		if hasStorage { return }
		var name = "disk"
		var n = 2
		while FileManager.default.fileExists(atPath: configFilePath(file: "\(name).raw")) {
			name = "disk-\(n)"
			n += 1
		}
		try addNewStorageDisk(name: name, size: minimumSize)
	}
}
