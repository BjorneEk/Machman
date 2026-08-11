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

	// Every owned file, parsed into role/tag/fileName, sorted by path.
	static func ownedFiles(kernelsDir: String) -> [OwnedKernelFile] {
		let fm = FileManager.default
		var result: [OwnedKernelFile] = []
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
		return result.sorted { $0.path < $1.path }
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

	// Remove an owned file (and its now-empty tag dir). Refuses paths outside the kernels dir.
	static func delete(path: String, kernelsDir: String) throws {
		guard isOwned(path, kernelsDir: kernelsDir) else {
			throw MachmanError(
				code: .invalidArgument, message: "'\(path)' is not an owned kernel file")
		}
		let fm = FileManager.default
		if fm.fileExists(atPath: path) {
			try fm.removeItem(atPath: path)
		}
		let tagDir = (path as NSString).deletingLastPathComponent
		if let contents = try? fm.contentsOfDirectory(atPath: tagDir), contents.isEmpty {
			try? fm.removeItem(atPath: tagDir)
		}
	}
}
