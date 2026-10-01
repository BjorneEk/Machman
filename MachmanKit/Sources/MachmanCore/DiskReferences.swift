//
//  DiskReferences.swift
//  MachmanCore
//
//  Cross-VM file use (C5). A VM may attach a file that another VM's folder holds — the
//  original of a VM saved from a safe run keeps using the disks the run wrote, which move
//  into the saved VM's folder — so deleting or renaming that folder, or removing or
//  renaming that disk there, would pull the file out from under the other VM. These guards
//  refuse such moves. Starting a second writer of one disk file is the router's refusal
//  (RoutingMachman.checkSharedDisks).
//

import Foundation
import MachmanAPI

extension VMConfig {
	// Every absolute path this config names — fromUrl images, isos, the kernel and its
	// initramfs: the set rewriteOwnedPaths re-points when a folder moves.
	var referencedPaths: [String] {
		var paths = disks.compactMap { disk -> String? in
			switch disk.kind {
			case .fromUrl(let url), .iso(let url): return url.path
			case .storage: return nil
			}
		}
		if let kernel = kernelSettings {
			paths.append(kernel.kernelPath)
			if let initrd = kernel.initialRamdiskPath { paths.append(initrd) }
		}
		return paths.filter { !$0.isEmpty }
	}

	// The file a disk entry owns — deleteDisk's rule: a storage raw, or an iso inside the
	// VM's folder. nil for a reference, whose removal only disconnects it.
	func ownedFile(of disk: VMDisk) -> String? {
		switch disk.kind {
		case .storage(let name, _):
			return configFilePath(file: "\(name).raw")
		case .iso(let url) where url.path.hasPrefix(vmDirPath() + "/"):
			return url.path
		case .iso, .fromUrl:
			return nil
		}
	}
}

extension VMRegistry {
	struct ForeignReference: Equatable {
		let vm: String     // the VM that uses the file
		let path: String   // the path its config names
	}

	// The first other VM (by name) whose config names `path` or anything inside it.
	// Lexical: paths are compared standardized, never through symlinks. The daemon's copy
	// of a hosted VM's config can be stale, which only ever over-refuses.
	func foreignReference(to path: String, excluding name: String) -> ForeignReference? {
		let target = (path as NSString).standardizingPath
		for other in vms.keys.sorted() where other != name {
			guard let config = vms[other]?.config else { continue }
			for referenced in config.referencedPaths {
				let candidate = (referenced as NSString).standardizingPath
				if candidate == target || candidate.hasPrefix(target + "/") {
					return ForeignReference(vm: other, path: candidate)
				}
			}
		}
		return nil
	}

	func foreignUseRefusal(_ ref: ForeignReference, owner: String) -> MachmanError {
		MachmanError(
			code: .invalidState,
			message: "\(ref.vm) uses \((ref.path as NSString).lastPathComponent) from "
				+ "\(owner)'s folder — remove that disk from \(ref.vm) first")
	}

	// vm.disk.remove: deleting an owned file another VM uses would destroy its disk.
	func removeDisk(_ disk: VMDisk, from vm: VirtualMachine) throws {
		try refuseForeignUse(of: vm.config.ownedFile(of: disk), in: vm)
		try vm.config.deleteDisk(disk: disk)
	}

	// vm.disk.rename: the owned raw moves, and another VM naming it would lose it.
	func renameStorageDisk(id: String, of vm: VirtualMachine, to newName: String) throws {
		let disk = vm.config.disks.first { $0.id == id }
		try refuseForeignUse(of: disk.flatMap { vm.config.ownedFile(of: $0) }, in: vm)
		try vm.config.renameStorageDisk(id: id, to: newName)
	}

	private func refuseForeignUse(of file: String?, in vm: VirtualMachine) throws {
		let owner = vm.config.name
		guard let file, let ref = foreignReference(to: file, excluding: owner) else { return }
		throw foreignUseRefusal(ref, owner: owner)
	}
}
