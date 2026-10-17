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
	// True when `path` is under this VM's kernels dir. Lexical, with ".." resolved first:
	// a raw prefix check let "<kernels>/../disk.raw" through (D16).
	static func isOwned(_ path: String, kernelsDir: String) -> Bool {
		let file = URL(fileURLWithPath: path).standardized.pathComponents
		let dir = URL(fileURLWithPath: kernelsDir).standardized.pathComponents
		return file.count > dir.count && file.starts(with: dir)
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
				for file in (try? fm.contentsOfDirectory(atPath: tagDir)) ?? []
					where isKernelFile(tagDir + "/" + file) {
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
				guard isKernelFile(path) else { continue }
				let role: KernelRole
				if path == kernelPath { role = .kernel }
				else if path == initrdPath { role = .initramfs }
				else { role = inferRole(fileName: file) }
				result.append(OwnedKernelFile(role: role, tag: store, fileName: file, path: path))
			}
		}

		return result.sorted { $0.path < $1.path }
	}

	// What a store dir holds that counts as a kernel file: not a directory, and not a hidden
	// name — Finder drops a .DS_Store into any folder the user opens, and listed as an owned
	// file it kept the Kernel section after the last real kernel went (D30).
	private static func isKernelFile(_ path: String) -> Bool {
		guard !(path as NSString).lastPathComponent.hasPrefix(".") else { return false }
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
			&& !isDirectory.boolValue
	}

	// Best-effort role for a legacy file the config doesn't reference, by name.
	private static func inferRole(fileName: String) -> KernelRole {
		let name = fileName.lowercased()
		let initramfsHints = ["initramfs", "initrd", "ramdisk", "rootfs", "cpio"]
		return initramfsHints.contains(where: name.contains) ? .initramfs : .kernel
	}

	// Whether a tag dir holds a kernel file already: a tag names one file (D35, K13).
	static func holdsKernelFile(_ tagDir: String) -> Bool {
		((try? FileManager.default.contentsOfDirectory(atPath: tagDir)) ?? []).contains {
			isKernelFile(tagDir + "/" + $0)
		}
	}

	// A second file under one tag drew two identical rows that the Tag field and its rename
	// treated as one (D35): refused, saying why (K13).
	static func tagTaken(_ tag: String) -> MachmanError {
		MachmanError(
			code: .alreadyExists, message: "\u{201C}\(tag)\u{201D} already holds a kernel file")
	}

	// Copy sourcePath into <kernelsDir>/<role>/<tag>/<basename> and return the new owned path.
	// Staged (D39): the copy lands in a hidden folder at the VM folder's top level, named like
	// a disk import's staging so the daemon's startup sweep (DiskImport.sweepStaleStaging)
	// takes whatever a crash leaves there, and that folder then becomes the tag dir in one
	// exclusive rename. A throw, kill or full disk mid-copy never leaves a truncated file under
	// the tag, and of two imports into one tag only one lands (K13). Like every new file in a VM
	// folder (D40), the file is owner-only and so is the folder that becomes its tag dir.
	// `transfer` is the copy's test seam; the default is the clone-first engine disk imports use.
	static func promote(
		role: KernelRole, sourcePath: String, kernelsDir: String, tag: String,
		transfer: ((String, String) throws -> Void)? = nil
	) throws -> String {
		let fm = FileManager.default
		guard fm.fileExists(atPath: sourcePath) else {
			throw MachmanError(code: .notFound, message: "No file at \(sourcePath)")
		}
		let trimmed = try NameRule.kernelTag.normalized(tag)
		let roleDir = kernelsDir + "/" + role.rawValue
		let tagDir = roleDir + "/" + trimmed
		guard !holdsKernelFile(tagDir) else { throw tagTaken(trimmed) }
		let basename = (sourcePath as NSString).lastPathComponent
		let staging = (kernelsDir as NSString).deletingLastPathComponent + "/"
			+ DiskImport.stagingPrefix + UUID().uuidString
		do {
			try fm.createDirectory(
				atPath: staging, withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700])
			let staged = staging + "/" + basename
			if let transfer {
				try transfer(sourcePath, staged)
			} else {
				try FileTransfer.copy(src: sourcePath, dst: staged)
			}
			try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged)
			excludeFromBackup(path: staged)   // owned now; the attribute rides the rename
			try fm.createDirectory(atPath: roleDir, withIntermediateDirectories: true)
			try place(staging, at: tagDir, tag: trimmed)
		} catch {
			try? fm.removeItem(atPath: staging)
			throw error
		}
		return tagDir + "/" + basename
	}

	// The staged folder becomes the tag dir, never over one: a tag dir that holds a kernel file
	// refuses (K13); one left empty — its last file deleted beside Finder's .DS_Store — is
	// cleared and taken.
	private static func place(_ staging: String, at tagDir: String, tag: String) throws {
		for _ in 0..<2 {
			if try DiskImport.placeExclusively(staging, at: tagDir) { return }
			guard !holdsKernelFile(tagDir) else { throw tagTaken(tag) }
			if (try? FileManager.default.contentsOfDirectory(atPath: tagDir)) == [".DS_Store"] {
				try? FileManager.default.removeItem(atPath: tagDir + "/.DS_Store")
			}
			_ = removeEmptyDirectory(tagDir)
		}
		throw tagTaken(tag)
	}

	// Move an owned file to a new tag: <role>/<oldTag>/<file> → <role>/<newTag>/<file>,
	// dropping the old tag dir if it emptied. Returns the new path. Legacy-layout files
	// (no role level) refuse — re-import gives them the current layout.
	static func rename(
		path rawPath: String, kernelsDir rawKernelsDir: String, newTag: String
	) throws -> String {
		let fm = FileManager.default
		let path = URL(fileURLWithPath: rawPath).standardized.path
		let kernelsDir = URL(fileURLWithPath: rawKernelsDir).standardized.path
		guard isOwned(path, kernelsDir: kernelsDir) else {
			throw MachmanError(
				code: .invalidArgument,
				message: "\((path as NSString).lastPathComponent) isn’t a kernel file this VM "
					+ "owns")
		}
		let rel = path.dropFirst(kernelsDir.count + 1).split(separator: "/").map(String.init)
		guard rel.count == 3,
			rel[0] == KernelRole.kernel.rawValue || rel[0] == KernelRole.initramfs.rawValue
		else {
			throw MachmanError(
				code: .invalidArgument,
				message: "This kernel file uses an old layout — import it again to rename it")
		}
		let trimmed = try NameRule.kernelTag.normalized(newTag)
		guard trimmed != rel[1] else { return path }
		let newDir = kernelsDir + "/" + rel[0] + "/" + trimmed
		let newPath = newDir + "/" + rel[2]
		let oldDir = kernelsDir + "/" + rel[0] + "/" + rel[1]
		// A change of letter case only finds the same tag dir on a case-insensitive volume
		// (D36): the dir itself takes the new spelling.
		if fm.fileExists(atPath: newPath), isSameFile(path, newPath) {
			try fm.moveItem(atPath: oldDir, toPath: newDir)
			return newPath
		}
		guard !fm.fileExists(atPath: newPath) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "\u{201C}\(trimmed)\u{201D} already holds a file named "
					+ "\u{201C}\(rel[2])\u{201D}")
		}
		// A tag names one kernel file, by a re-tag as by an import (D35, K13).
		guard !holdsKernelFile(newDir) else { throw tagTaken(trimmed) }
		try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)
		try fm.moveItem(atPath: path, toPath: newPath)
		if let leftovers = try? fm.contentsOfDirectory(atPath: oldDir), leftovers.isEmpty {
			try? fm.removeItem(atPath: oldDir)
		}
		return newPath
	}

	// Remove an owned file and every container dir it empties — tag dir, role dir, and the
	// kernels dir itself when the last file leaves. Refuses paths outside the kernels dir
	// and directories (a role or tag dir is not a file to delete).
	static func delete(path rawPath: String, kernelsDir rawKernelsDir: String) throws {
		let path = URL(fileURLWithPath: rawPath).standardized.path
		let kernelsDir = URL(fileURLWithPath: rawKernelsDir).standardized.path
		let fm = FileManager.default
		var isDirectory: ObjCBool = false
		let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
		guard isOwned(path, kernelsDir: kernelsDir), !(exists && isDirectory.boolValue) else {
			throw MachmanError(
				code: .invalidArgument,
				message: "\((rawPath as NSString).lastPathComponent) isn’t a kernel file this VM "
					+ "owns")
		}
		if exists {
			try fm.removeItem(atPath: path)
		}
		// Walk up from the file's dir, stopping at the first level that still holds
		// something; legacy-layout files (no role level) just make fewer hops.
		var dir = (path as NSString).deletingLastPathComponent
		while dir.hasPrefix(kernelsDir) {
			// Finder's .DS_Store is not the user's: it doesn't keep an emptied dir alive (D30).
			if (try? fm.contentsOfDirectory(atPath: dir)) == [".DS_Store"] {
				try? fm.removeItem(atPath: dir + "/.DS_Store")
			}
			guard removeEmptyDirectory(dir) else { break }
			if dir == kernelsDir { break }
			dir = (dir as NSString).deletingLastPathComponent
		}
	}
}
