//
//  KernelStore.swift
//  MachmanCore
//
//  Owned kernel/initramfs files for a VM: copies of user-picked images that live inside the VM
//  directory at <vm>/kernels/<name>/<file>, so a direct-kernel-boot VM travels with its kernel
//  (ownership = residency, the disk model). Path-based and nonisolated so the copy can run off
//  the main actor.
//

import Foundation
import MachmanAPI

enum KernelStore {
	// True when `path` is an owned file under this VM's kernels dir.
	static func isOwned(_ path: String, kernelsDir: String) -> Bool {
		path.hasPrefix(kernelsDir + "/")
	}

	// Every owned file, absolute paths, sorted.
	static func ownedFiles(kernelsDir: String) -> [String] {
		let fm = FileManager.default
		guard let stores = try? fm.contentsOfDirectory(atPath: kernelsDir) else { return [] }
		var files: [String] = []
		for store in stores {
			let storeDir = kernelsDir + "/" + store
			var isDir: ObjCBool = false
			guard fm.fileExists(atPath: storeDir, isDirectory: &isDir), isDir.boolValue else {
				continue
			}
			for file in (try? fm.contentsOfDirectory(atPath: storeDir)) ?? [] {
				files.append(storeDir + "/" + file)
			}
		}
		return files.sorted()
	}

	// Copy sourcePath into <kernelsDir>/<storeName>/<basename> and return the new owned path.
	static func promote(sourcePath: String, kernelsDir: String, storeName: String) throws -> String {
		let fm = FileManager.default
		guard fm.fileExists(atPath: sourcePath) else {
			throw MachmanError(code: .notFound, message: "no file at '\(sourcePath)'")
		}
		let trimmed = storeName.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, !trimmed.contains("/") else {
			throw MachmanError(code: .invalidArgument, message: "invalid name '\(storeName)'")
		}
		let storeDir = kernelsDir + "/" + trimmed
		let basename = (sourcePath as NSString).lastPathComponent
		let dest = storeDir + "/" + basename
		guard !fm.fileExists(atPath: dest) else {
			throw MachmanError(
				code: .alreadyExists, message: "'\(trimmed)/\(basename)' already exists")
		}
		try fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true)
		try fm.copyItem(atPath: sourcePath, toPath: dest)
		excludeFromBackup(path: dest)
		return dest
	}

	// Remove an owned file (and its now-empty store dir). Refuses paths outside the kernels dir.
	static func delete(path: String, kernelsDir: String) throws {
		guard isOwned(path, kernelsDir: kernelsDir) else {
			throw MachmanError(
				code: .invalidArgument, message: "'\(path)' is not an owned kernel file")
		}
		let fm = FileManager.default
		if fm.fileExists(atPath: path) {
			try fm.removeItem(atPath: path)
		}
		let storeDir = (path as NSString).deletingLastPathComponent
		if let contents = try? fm.contentsOfDirectory(atPath: storeDir), contents.isEmpty {
			try? fm.removeItem(atPath: storeDir)
		}
	}
}
