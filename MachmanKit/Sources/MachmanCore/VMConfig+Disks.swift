//
//  VMConfig+Disks.swift
//  MachmanCore
//
//  A VM's disks: a backing file's size, adding one (one entry per file; a new owned image under
//  the size rule), replacing one (promote), renaming and growing an owned image, deleting one
//  with the file it owns, and keeping owned images out of Time Machine.
//

import Foundation
import MachmanAPI

extension VMConfig {
	// The backing file's size, through a link when the entry names one (D23).
	func getDiskSize(disk: VMDisk) -> UInt64? {
		let url = switch disk.kind {
			case .fromUrl(let url):
				url
			case .storage(let name, _):
				localURL(file: "\(name).raw")
			case .iso(let url):
				url
		}
		return fileSize(atPath: url.path)
	}

	// Removes the disk from the config; for .storage also deletes the backing image file.
	// Destructive — confirmation is the caller's job. Ownership = residency: storage raws
	// and isos living INSIDE the VM dir (imported/promoted) are deleted with their entry;
	// external files are only disconnected. The config saves first (D22): a failed save
	// keeps the entry and its file. Once it saved, the disk IS removed — an owned file that
	// won't delete stays behind as an orphan, returned for the caller to report, never
	// thrown (review F3: the removal happened).
	@discardableResult
	func deleteDisk(disk: VMDisk) throws -> String? {
		let before = disks
		disks.removeAll { $0 == disk }
		do {
			try saveVMConfig()
		} catch {
			disks = before
			throw error
		}
		guard let file = ownedFile(of: disk), FileManager.default.fileExists(atPath: file)
		else { return nil }
		do {
			try FileManager.default.removeItem(atPath: file)
			return nil
		} catch {
			MachmanLogger.log(.passiveError,
				"\(name): removed the disk, but \(file) couldn’t be deleted: \(error)")
			return file
		}
	}

	// Swap a disk entry in place (vm.disk.promote): position and the entry's flags (safe,
	// enabled) stay; only the kind changes.
	func replaceDisk(id: String, kind: VMDiskKind) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		disks[index] = disks[index].withKind(kind)
		try saveVMConfig()
	}

	// One entry per file (D34): a second entry for a file the VM already attaches shares the
	// first one's id, so neither can be addressed alone (removing one removed both), and a
	// start attached the file twice, writable, past the shared-disk guard's per-file sets.
	public func addDisk(disk: VMDisk) throws {
		let file = attachedFile(of: disk)
		if disks.contains(where: { isSameFile(attachedFile(of: $0), file) }) {
			throw MachmanError(
				code: .alreadyExists,
				message: "\(name) already uses “\((file as NSString).lastPathComponent)”")
		}
		disks.append(disk)
		try saveVMConfig()
	}

	public func addIsoDisk(isoUrl: URL) throws {
		try addDisk(disk: VMDisk(kind: .iso(isoUrl)))
	}

	// A new owned image, <name>.raw. The name follows the disk-name rule and must be new to
	// this VM — in its config and in its folder: creating over an existing file would wipe
	// that disk, even under a running VM (D15).
	public func addNewStorageDisk(name raw: String, size: UInt64) throws {
		let name = try NameRule.diskName.normalized(raw)
		try Self.validateRawSize(size)
		let taken = disks.contains {
			if case .storage(let existing, _) = $0.kind { return existing == name }
			return false
		}
		guard !taken else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a disk named \u{201C}\(name)\u{201D}")
		}
		let path = configFilePath(file: "\(name).raw")
		try Self.createDiskImage(atPath: path, size: size, name: name)
		excludeFromBackup(path: path)
		do {
			try addDisk(disk: VMDisk(kind: .storage(name, size)))
		} catch {
			disks.removeAll { $0.id == "storage:\(name)" }
			try? FileManager.default.removeItem(atPath: path)
			throw error
		}
	}

	// One size rule for every raw this engine sizes, new or grown (D24): VZ attaches raw
	// images in whole 512-byte sectors only — anything else fails the next start with
	// "Couldn’t attach x.raw" — and ftruncate takes an off_t.
	static func validateRawSize(_ size: UInt64) throws {
		guard size > 0, size % 512 == 0, size <= UInt64(Int64.max) else {
			throw MachmanError(
				code: .invalidArgument,
				message: "A disk’s size must be a positive multiple of 512 bytes")
		}
	}

	// O_EXCL: the image is created or the call fails — an existing file is never replaced.
	// Sparse: ftruncate allocates nothing. Owner-only, like every disk Machman makes (D40).
	static func createDiskImage(atPath path: String, size: UInt64, name: String) throws {
		let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
		guard fd >= 0 else {
			let code = errno
			if code == EEXIST {
				throw MachmanError(
					code: .alreadyExists,
					message: "A file named \u{201C}\(name).raw\u{201D} is already in the "
						+ "VM’s folder")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t create \(name).raw: \(String(cString: strerror(code)))")
		}
		defer { close(fd) }
		guard ftruncate(fd, off_t(size)) == 0 else {
			let code = errno
			unlink(path)
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t size \(name).raw: \(String(cString: strerror(code)))")
		}
	}

	// Keep VM disks out of Time Machine. Only images the VM owns are touched: a .fromUrl or .iso
	// disk belongs to the user, who may well want it backed up.
	func excludeDiskImagesFromBackup() {
		for disk in disks {
			guard case .storage(let name, _) = disk.kind else { continue }
			excludeFromBackup(path: configFilePath(file: "\(name).raw"))
		}
	}

	// Rename an owned storage disk: moves the backing file and rewrites the disk entry
	// (the disk's id is derived from the name, so callers re-resolve after this). A failed
	// save moves the file back (D22): the config on disk still names the old one.
	func renameStorageDisk(id: String, to newName: String) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		guard case .storage(let oldName, let size) = disks[index].kind else {
			throw MachmanError(
				code: .invalidArgument, message: "Only owned disks can be renamed")
		}
		let trimmed = try NameRule.diskName.normalized(newName)
		guard trimmed != oldName else { return }
		guard !disks.contains(where: { $0.id == "storage:\(trimmed)" }) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "This VM already has a disk named \u{201C}\(trimmed)\u{201D}")
		}
		let oldPath = configFilePath(file: "\(oldName).raw")
		let newPath = configFilePath(file: "\(trimmed).raw")
		// A change of letter case only finds the disk's own file on a case-insensitive
		// volume (D36): that is no other file, and the move renames it.
		guard !FileManager.default.fileExists(atPath: newPath) || isSameFile(oldPath, newPath)
		else {
			throw MachmanError(
				code: .alreadyExists,
				message: "A file named \u{201C}\(trimmed).raw\u{201D} is already in the "
					+ "VM’s folder")
		}
		try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
		disks[index].kind = .storage(trimmed, size)
		do {
			try saveVMConfig()
		} catch {
			disks[index].kind = .storage(oldName, size)
			do {
				try FileManager.default.moveItem(atPath: newPath, toPath: oldPath)
			} catch let moveBack {
				MachmanLogger.log(.passiveError,
					"\(name): \(trimmed).raw couldn’t move back to \(oldName).raw: \(moveBack)")
			}
			throw error
		}
	}

	// MARK: - Disk resize (vm.disk.resize) — grow-only, owned storage only.

	func growStorageDisk(id: String, to newSize: UInt64) throws {
		guard let index = disks.firstIndex(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		guard case .storage(let storageName, _) = disks[index].kind else {
			throw MachmanError(
				code: .invalidArgument, message: "Only owned disks can grow")
		}
		let path = configFilePath(file: "\(storageName).raw")
		let current = getDiskSize(disk: disks[index]) ?? 0
		guard newSize > current else {
			throw MachmanError(
				code: .invalidArgument,
				message: "Disks only grow — enter more than \(ByteSize.display(current))")
		}
		try VMConfig.validateRawSize(newSize)
		let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
		defer { try? handle.close() }
		try handle.truncate(atOffset: newSize)
		// Also refresh the persisted size so the config stops going stale.
		disks[index].kind = .storage(storageName, newSize)
		try saveVMConfig()
	}
}
