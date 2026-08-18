//
//  KernelStore.swift
//  MachmanCore
//
//  Owned kernel/initramfs files for a VM: copies of user-picked images that live inside the VM
//  directory at <vm>/kernels/<role>/<tag>/<file>, so a direct-kernel-boot VM travels with its
//  kernel (ownership = residency, the disk model). role separates the kernel and initramfs
//  pickers; tag is a user-facing label. Path-based and nonisolated so the copy can run off the
//  main actor.
//

import Foundation
import MachmanAPI

enum KernelStore {
	// True when `path` is an owned file under this VM's kernels dir.
	static func isOwned(_ path: String, kernelsDir: String) -> Bool {
		path.hasPrefix(kernelsDir + "/")
	}

	// Every owned file, parsed into role/tag/fileName, sorted by path. The optional kernel/initrd
	// paths (the config's current references) let legacy files be assigned the right role.
	static func ownedFiles(
		kernelsDir: String, kernelPath: String? = nil, initrdPath: String? = nil
	) -> [OwnedKernelFile] {
		let fm = FileManager.default
		var result: [OwnedKernelFile] = []
		let roleDirNames = Set([KernelRole.kernel.rawValue, KernelRole.initramfs.rawValue])

		// Current layout: <kernelsDir>/<role>/<tag>/<file>.
		for role in [KernelRole.kernel, .initramfs] {
			let roleDir = kernelsDir + "/" + role.rawValue
			guard let tags = try? fm.contentsOfDirectory(atPath: roleDir) else { continue }
			for tag in tags {
				let tagDir = roleDir + "/" + tag
				var isDir: ObjCBool = false
				guard fm.fileExists(atPath: tagDir, isDirectory: &isDir), isDir.boolValue else {
					continue
				}
				for file in (try? fm.contentsOfDirectory(atPath: tagDir)) ?? [] {
					result.append(OwnedKernelFile(
						role: role, tag: tag, fileName: file, path: tagDir + "/" + file))
				}
			}
		}

		// Legacy layout (before the role level existed): <kernelsDir>/<storeName>/<file>. Files
		// copied in by an older build are stranded from the scan above, so surface them where they
		// lie (no move) — role from the config's live references, else inferred from the file name.
		for store in (try? fm.contentsOfDirectory(atPath: kernelsDir)) ?? []
			where !roleDirNames.contains(store) {
			let storeDir = kernelsDir + "/" + store
			var storeIsDir: ObjCBool = false
			guard fm.fileExists(atPath: storeDir, isDirectory: &storeIsDir), storeIsDir.boolValue
			else { continue }
			for file in (try? fm.contentsOfDirectory(atPath: storeDir)) ?? [] {
				let path = storeDir + "/" + file
				var fileIsDir: ObjCBool = false
				guard fm.fileExists(atPath: path, isDirectory: &fileIsDir), !fileIsDir.boolValue
				else { continue }
				let role: KernelRole
				if path == kernelPath { role = .kernel }
				else if path == initrdPath { role = .initramfs }
				else { role = inferRole(fileName: file) }
				result.append(OwnedKernelFile(role: role, tag: store, fileName: file, path: path))
			}
		}

		return result.sorted { $0.path < $1.path }
	}

	// Best-effort role for a legacy file the config doesn't reference, by name.
	private static func inferRole(fileName: String) -> KernelRole {
		let name = fileName.lowercased()
		let initramfsHints = ["initramfs", "initrd", "ramdisk", "rootfs", "cpio"]
		return initramfsHints.contains(where: name.contains) ? .initramfs : .kernel
	}

	// Copy sourcePath into <kernelsDir>/<role>/<tag>/<basename> and return the new owned path.
	static func promote(
		role: KernelRole, sourcePath: String, kernelsDir: String, tag: String
	) throws -> String {
		let fm = FileManager.default
		guard fm.fileExists(atPath: sourcePath) else {
			throw MachmanError(code: .notFound, message: "no file at '\(sourcePath)'")
		}
		let trimmed = tag.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, !trimmed.contains("/") else {
			throw MachmanError(code: .invalidArgument, message: "invalid tag '\(tag)'")
		}
		let tagDir = kernelsDir + "/" + role.rawValue + "/" + trimmed
		let basename = (sourcePath as NSString).lastPathComponent
		let dest = tagDir + "/" + basename
		guard !fm.fileExists(atPath: dest) else {
			throw MachmanError(
				code: .alreadyExists, message: "'\(trimmed)/\(basename)' already exists")
		}
		try fm.createDirectory(atPath: tagDir, withIntermediateDirectories: true)
		try fm.copyItem(atPath: sourcePath, toPath: dest)
		excludeFromBackup(path: dest)
		return dest
	}

	// Move an owned file to a new tag: <role>/<oldTag>/<file> → <role>/<newTag>/<file>,
	// dropping the old tag dir if it emptied. Returns the new path. Legacy-layout files
	// (no role level) refuse — re-import gives them the current layout.
	static func rename(path: String, kernelsDir: String, newTag: String) throws -> String {
		let fm = FileManager.default
		guard isOwned(path, kernelsDir: kernelsDir) else {
			throw MachmanError(
				code: .invalidArgument, message: "'\(path)' is not an owned kernel file")
		}
		let rel = path.dropFirst(kernelsDir.count + 1).split(separator: "/").map(String.init)
		guard rel.count == 3,
			rel[0] == KernelRole.kernel.rawValue || rel[0] == KernelRole.initramfs.rawValue
		else {
			throw MachmanError(
				code: .invalidArgument,
				message: "legacy-layout kernel file — re-import it to rename")
		}
		let trimmed = newTag.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, !trimmed.contains("/") else {
			throw MachmanError(code: .invalidArgument, message: "invalid tag '\(newTag)'")
		}
		guard trimmed != rel[1] else { return path }
		let newDir = kernelsDir + "/" + rel[0] + "/" + trimmed
		let newPath = newDir + "/" + rel[2]
		guard !fm.fileExists(atPath: newPath) else {
			throw MachmanError(
				code: .alreadyExists, message: "'\(trimmed)/\(rel[2])' already exists")
		}
		try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)
		try fm.moveItem(atPath: path, toPath: newPath)
		let oldDir = kernelsDir + "/" + rel[0] + "/" + rel[1]
		if let leftovers = try? fm.contentsOfDirectory(atPath: oldDir), leftovers.isEmpty {
			try? fm.removeItem(atPath: oldDir)
		}
		return newPath
	}

	// Remove an owned file and every container dir it empties — tag dir, role dir, and the
	// kernels dir itself when the last file leaves. Refuses paths outside the kernels dir.
	static func delete(path: String, kernelsDir: String) throws {
		guard isOwned(path, kernelsDir: kernelsDir) else {
			throw MachmanError(
				code: .invalidArgument, message: "'\(path)' is not an owned kernel file")
		}
		let fm = FileManager.default
		if fm.fileExists(atPath: path) {
			try fm.removeItem(atPath: path)
		}
		// Walk up from the file's dir, stopping at the first level that still holds
		// something; legacy-layout files (no role level) just make fewer hops.
		var dir = (path as NSString).deletingLastPathComponent
		while dir.hasPrefix(kernelsDir) {
			guard removeEmptyDirectory(dir) else { break }
			if dir == kernelsDir { break }
			dir = (dir as NSString).deletingLastPathComponent
		}
	}
}
