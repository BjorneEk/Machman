//
//  LocalMachman+Disks.swift
//  MachmanCore
//
//  vm.disk.*: adding a disk (a new owned image, or an image or ISO by reference), removing one,
//  importing and promoting one (the copy into the VM's folder they share), and renaming and
//  growing an owned image.
//

import Foundation
import MachmanAPI

extension LocalMachman {
	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		// A referenced image or ISO passes the import's format gate first (D29), before the
		// lookup, so nothing awaits between finding the VM and changing its config. The wait
		// between the router choosing this process and the change landing is guarded by the
		// router's claim on the VM (E65): no start hands the config to a vmhost meanwhile.
		if disk.type == .image || disk.type == .iso, let path = disk.path, !path.isEmpty {
			try await checkAttachable(path)
		}
		let vm = try lookup(name)
		switch disk.type {
		case .storage:
			guard let diskName = disk.name, !diskName.isEmpty, let size = disk.sizeBytes else {
				throw MachmanError(
					code: .invalidArgument, message: "A new disk needs a name and a size")
			}
			try vm.config.addNewStorageDisk(name: diskName, size: size)
		case .iso:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "An ISO disk needs a path")
			}
			try vm.config.addIsoDisk(isoUrl: URL(fileURLWithPath: path))
		case .image:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "A disk image needs a path")
			}
			try vm.config.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: path))))
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "Unknown disk type")
		}
		registry.events.emit(.listChanged)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		let vm = try lookup(name)
		guard let disk = vm.config.disks.first(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		try registry.removeDisk(disk, from: vm)
		registry.events.emit(.listChanged)
	}

	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		let vm = try lookup(name)
		let imported = try await copyIntoVM(
			vm, name: name, sourcePath: path, kind: OperationInfo.Kind.importDisk)
		try vm.config.addDisk(disk: imported)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		let vm = try lookup(name)
		guard let disk = vm.config.disks.first(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		let vmDir = vm.config.vmDirPath()
		let sourcePath: String
		switch disk.kind {
		case .storage:
			throw MachmanError(
				code: .invalidState, message: "This disk is already owned by the VM")
		case .iso(let url):
			guard !url.path.hasPrefix(vmDir + "/") else {
				throw MachmanError(
					code: .invalidState, message: "This disk is already owned by the VM")
			}
			sourcePath = url.path
		case .fromUrl(let url):
			sourcePath = url.path
		}
		let promoted = try await copyIntoVM(
			vm, name: name, sourcePath: sourcePath, kind: OperationInfo.Kind.promoteDisk)
		try vm.config.replaceDisk(id: diskID, kind: promoted.kind)   // the flags carry
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The shared import mechanics: gather taken names on-actor, then detach the sniff+copy
	// (external images can be real cross-volume byte copies). Progress reuses copyProgress
	// AND registers an operation (dual-emitted for older clients).
	private func copyIntoVM(
		_ vm: VirtualMachine, name: String, sourcePath: String, kind: String
	) async throws -> VMDisk {
		let vmDir = vm.config.vmDirPath()
		let taken = Set(vm.config.disks.compactMap { disk -> String? in
			if case .storage(let storageName, _) = disk.kind { return storageName }
			return nil
		})
		let events = registry.events
		let center = operationCenter
		let cancelFlag = CancelFlag()
		let file = (sourcePath as NSString).lastPathComponent
		let verb = kind == OperationInfo.Kind.promoteDisk ? "Promoting" : "Importing"
		let opID = center.begin(
			kind: kind, vm: name, label: "\(verb) \(file)", cancel: { cancelFlag.set() })
		do {
			let disk = try await Task.detached(priority: .userInitiated) {
				try DiskImport.importFile(
					src: sourcePath, vmDir: vmDir, takenStorageNames: taken,
					progress: { copied, total in
						Task { @MainActor in
							events.emit(.copyProgress(
								vm: name, copiedBytes: copied, totalBytes: total))
							center.update(
								opID,
								fraction: total > 0 ? Double(copied) / Double(total) : nil,
								completedBytes: Int64(copied), totalBytes: Int64(total))
						}
					},
					isCancelled: { cancelFlag.get() })
			}.value
			center.finish(opID, state: OperationInfo.State.succeeded)
			return disk
		} catch {
			center.finish(
				opID,
				state: cancelFlag.get()
					? OperationInfo.State.cancelled : OperationInfo.State.failed,
				message: MachmanError.userMessage(for: error))
			throw error
		}
	}

	public func renameDisk(vm name: String, diskID: String, newName: String)
		async throws -> VMInfo {
		let vm = try lookup(name)
		guard !vm.state.isRunning else {
			throw MachmanError(
				code: .invalidState, message: "Stop \(name) before renaming its disks")
		}
		try registry.renameStorageDisk(id: diskID, of: vm, to: newName)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		let vm = try lookup(name)
		try vm.config.growStorageDisk(id: diskID, to: sizeBytes)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}
}
