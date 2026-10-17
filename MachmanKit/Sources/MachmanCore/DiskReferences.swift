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
			case .storage, .unknown: return nil
			}
		}
		if let kernel = kernelSettings {
			paths.append(kernel.kernelPath)
			if let initrd = kernel.initialRamdiskPath { paths.append(initrd) }
		}
		return paths.filter { !$0.isEmpty }
	}

	// The files a start attaches writable: enabled storage raws and fromUrl images (isos
	// attach read-only), standardized for comparison.
	var writableDiskFiles: Set<String> { writableFiles(of: disks.filter(\.enabled)) }

	// The files a start leaves unattached: the ones only disabled entries name.
	var unattachedDiskFiles: Set<String> {
		everyWritableDiskFile.subtracting(writableDiskFiles)
	}

	// Every file the entries attach writable once enabled, whatever their flags say now.
	var everyWritableDiskFile: Set<String> { writableFiles(of: disks) }

	private func writableFiles(of entries: [VMDisk]) -> Set<String> {
		Set(entries.compactMap { disk -> String? in
			switch disk.kind {
			case .storage(let name, _): return configFilePath(file: "\(name).raw")
			case .fromUrl(let url): return url.path
			case .iso, .unknown: return nil
			}
		}.map { ($0 as NSString).standardizingPath })
	}

	// The file a disk entry attaches: its storage raw, image or iso; nil for a newer Machman's
	// entry, whose file this build can't know (D38).
	func attachedFile(of disk: VMDisk) -> String? {
		switch disk.kind {
		case .storage(let name, _): return configFilePath(file: "\(name).raw")
		case .fromUrl(let url), .iso(let url): return url.path
		case .unknown: return nil
		}
	}

	// The file a disk entry owns — what deleteDisk deletes: a storage raw, or an iso inside
	// the VM's folder. nil for a reference, whose removal only disconnects it, and for a newer
	// Machman's entry (D38): removing it drops only the entry.
	func ownedFile(of disk: VMDisk) -> String? {
		switch disk.kind {
		case .storage(let name, _):
			return configFilePath(file: "\(name).raw")
		case .iso(let url) where url.path.hasPrefix(vmDirPath() + "/"):
			return url.path
		case .iso, .fromUrl, .unknown:
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
				+ "\(owner)’s folder — remove that disk from \(ref.vm) first")
	}

	// vm.disk.remove: deleting an owned file another VM uses would destroy its disk. An owned
	// file that won't delete once the entry is gone is an orphan the user is told about — the
	// removal itself succeeded (review F3).
	func removeDisk(_ disk: VMDisk, from vm: VirtualMachine) throws {
		try refuseForeignUse(of: vm.config.ownedFile(of: disk), in: vm)
		if let orphan = try vm.config.deleteDisk(disk: disk) {
			events.emit(.log(
				vm: vm.config.name, level: .warning, message: Self.orphanWarning(orphan)))
		}
	}

	// One sentence without the VM's name: the desktop shows it as "<VM>: …".
	static func orphanWarning(_ path: String) -> String {
		"\u{201C}\((path as NSString).lastPathComponent)\u{201D} couldn’t be deleted from the "
			+ "VM’s folder — remove it by hand."
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
