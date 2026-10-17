//
//  MacPlatform.swift
//  Machman
//
//  macOS-guest platform artifacts, persisted as sibling files next to the VM config (paralleling
//  vm_identifier / efi_vars.fd). Created during install (see MacInstaller); loaded on every boot.
//

import Foundation
import Virtualization
import MachmanAPI

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

	// The disk a macOS install restores onto (D32): VZ restores onto the first disk the VM
	// attaches. A retry — the VM is in macOS mode already: a failed or canceled install, or a
	// copy of an unfinished Mac — reuses its own first disk when that one can hold macOS,
	// switched on if it was off. Anything else (a switch from EFI or kernel boot, the mac
	// template) gets a NEW first disk, and the VM's other disks stay after it (K4): "disk", or
	// "disk-2", "disk-3"… when an orphan image (a .raw no config entry names) already holds
	// the name — creation never replaces a file. `diskID`: the disk the user picked instead
	// (K4), checked again here — the download took minutes — then moved first and switched on.
	func ensureMacSystemDisk(
		onto diskID: String? = nil, minimumSize: UInt64 = MacSystemDisk.newDiskBytes
	) throws {
		if let diskID {
			try placeMacSystemDisk(diskID)
			return
		}
		if case .macOS = boot, let first = disks.first, Self.canHoldMacOS(first) {
			if !first.enabled {
				disks[0].enabled = true
				try saveVMConfig()
			}
			return
		}
		var name = "disk"
		var n = 2
		while FileManager.default.fileExists(atPath: configFilePath(file: "\(name).raw")) {
			name = "disk-\(n)"
			n += 1
		}
		try addNewStorageDisk(name: name, size: minimumSize, first: true)
	}

	private func placeMacSystemDisk(_ diskID: String) throws {
		guard let index = disks.firstIndex(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		if let refusal = Self.macSystemDiskRefusal(disks[index]) { throw refusal }
		let before = disks
		var disk = disks.remove(at: index)
		disk.enabled = true
		disks.insert(disk, at: 0)
		do {
			try saveVMConfig()
		} catch {
			disks = before
			throw error
		}
	}

	// A disk macOS can be restored onto: a writable one this build knows.
	static func canHoldMacOS(_ disk: VMDisk) -> Bool {
		macSystemDiskRefusal(disk) == nil
	}

	// Why macOS can't be installed on a disk — its kind only. Its size is never a reason: the
	// switch sheet warns about a small one, and the install says if macOS doesn't fit (K15).
	static func macSystemDiskRefusal(_ disk: VMDisk) -> MachmanError? {
		switch disk.kind {
		case .storage, .fromUrl:
			return nil
		case .iso:
			return MachmanError(
				code: .invalidArgument, message: "macOS can’t be installed on an ISO")
		case .unknown:
			return MachmanError(
				code: .invalidArgument,
				message: "macOS can’t be installed on a disk a newer Machman added")
		}
	}
}
