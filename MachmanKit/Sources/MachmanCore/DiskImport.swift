//
//  DiskImport.swift
//  MachmanCore
//
//  vm.disk.import / vm.disk.promote's engine: sniff an external image's real format (the
//  file picker is not the gate — magic bytes are), copy it INTO the VM directory as an
//  owned file, and hand back the config entry to attach. Explicit paths, no globals —
//  the actor gathers names and mutates the config; this does the file work detached.
//

import Foundation
import MachmanAPI

enum DiskFormat: Equatable {
	case raw          // anything attachable as a block device
	case iso          // ISO9660 ("CD001" at 0x8001)
	case qcow         // "QFI\xfb" — NOT attachable by Virtualization.framework
	case unreadable

	static func sniff(path: String) -> DiskFormat {
		guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
		defer { try? handle.close() }
		guard let head = try? handle.read(upToCount: 4), !head.isEmpty else {
			return .unreadable
		}
		if head.count == 4, head[0] == 0x51, head[1] == 0x46,
			head[2] == 0x49, head[3] == 0xFB {
			return .qcow
		}
		if let _ = try? handle.seek(toOffset: 0x8001),
			let magic = try? handle.read(upToCount: 5), magic == Data("CD001".utf8) {
			return .iso
		}
		return .raw
	}
}

enum DiskImport {
	static let stagingPrefix = ".machman-import-"

	// Copies src into vmDir as an owned disk file and returns the entry to attach:
	// raw → .storage(<derived>, size) as <derived>.raw; iso → .iso(<vmDir>/<basename>).
	// Both are backup-excluded (VM-owned now). Throws typed errors for qcow, unreadable
	// files, and misaligned raw images (VZ would reject those at boot with an opaque error).
	// Names are derived when the copy LANDS (stagedCopy), against the directory as it is
	// then. `transfer` is stagedCopy's test seam.
	nonisolated static func importFile(
		src: String, vmDir: String, takenStorageNames: Set<String>,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil,
		transfer: ((String, String) throws -> Void)? = nil
	) throws -> VMDisk {
		let fm = FileManager.default
		guard fm.fileExists(atPath: src) else {
			throw MachmanError(code: .notFound, message: "No file at \(src)")
		}
		let size = fileSize(atPath: src) ?? 0
		switch DiskFormat.sniff(path: src) {
		case .qcow:
			throw MachmanError(
				code: .invalidArgument,
				message: "Machman can’t use qcow2 images — convert to raw first "
					+ "(qemu-img convert -O raw)")
		case .unreadable:
			throw MachmanError(code: .invalidArgument, message: "Couldn’t read \(src)")
		case .raw:
			guard size > 0, size % 512 == 0 else {
				throw MachmanError(
					code: .invalidArgument,
					message: "Raw disk images must be a non-empty multiple of 512 bytes, and "
						+ "\((src as NSString).lastPathComponent) is \(size) bytes")
			}
			let placed = try stagedCopy(
				src: src, vmDir: vmDir,
				name: {
					var taken = takenStorageNames
					for entry in (try? fm.contentsOfDirectory(atPath: vmDir)) ?? []
						where entry.hasSuffix(".raw") {
						taken.insert(String(entry.dropLast(4)))
					}
					return VMCopier.storageName(for: URL(fileURLWithPath: src), taken: taken)
						+ ".raw"
				},
				progress: progress, isCancelled: isCancelled, transfer: transfer)
			return VMDisk(kind: .storage(String(placed.dropLast(".raw".count)), size))
		case .iso:
			let base = URL(fileURLWithPath: src).lastPathComponent
			let placed = try stagedCopy(
				src: src, vmDir: vmDir,
				name: {
					// lstat, not fileExists: a dangling link still holds its name.
					var fileName = base
					var n = 2
					while (try? fm.attributesOfItem(atPath: vmDir + "/" + fileName)) != nil {
						let stem = URL(fileURLWithPath: base).deletingPathExtension()
							.lastPathComponent
						let ext = URL(fileURLWithPath: base).pathExtension
						fileName = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
						n += 1
					}
					return fileName
				},
				progress: progress, isCancelled: isCancelled, transfer: transfer)
			return VMDisk(kind: .iso(URL(fileURLWithPath: vmDir + "/" + placed)))
		}
	}

	// Copy via a hidden staged sibling and rename into place: a throw or cancel mid-copy
	// never leaves a partial file under the final name, and a crash leaves only a staged
	// name sweepStaleStaging recognizes. The transfer is injectable because the real
	// failure-after-partial-write cannot be reproduced on one APFS volume (clonefile is
	// atomic there); default is the clone-first engine. Returns the file name it landed
	// under: `name` derives one against the directory as it is when the copy lands, and
	// again whenever another import or a new disk took it meanwhile (D18).
	@discardableResult
	nonisolated static func stagedCopy(
		src: String, vmDir: String, name: () -> String,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil,
		transfer: ((String, String) throws -> Void)? = nil
	) throws -> String {
		let fm = FileManager.default
		let staging = vmDir + "/" + stagingPrefix + UUID().uuidString
		do {
			if let transfer {
				try transfer(src, staging)
			} else {
				try FileTransfer.copy(
					src: src, dst: staging, progress: progress, isCancelled: isCancelled)
			}
			excludeFromBackup(path: staging)   // owned now; the attribute rides the rename
			for _ in 0..<maxPlacementAttempts {
				let fileName = name()
				if try placeExclusively(staging, at: vmDir + "/" + fileName) {
					return fileName
				}
			}
			throw MachmanError(
				code: .alreadyExists, message: "No free name is left for the imported disk")
		} catch {
			try? fm.removeItem(atPath: staging)
			throw error
		}
	}

	// Each lost race re-derives a name past the one it lost; this only bounds a directory
	// that keeps producing new files.
	static let maxPlacementAttempts = 64

	// Renames staging to path unless path exists (RENAME_EXCL: atomic, never replaces);
	// false = the name is taken. A volume without RENAME_EXCL (ENOTSUP/EINVAL — some
	// network and FAT-family file systems) checks, then moves: the window is back there only.
	nonisolated static func placeExclusively(_ staging: String, at path: String) throws -> Bool {
		if renamex_np(staging, path, UInt32(RENAME_EXCL)) == 0 { return true }
		let code = errno
		switch code {
		case EEXIST:
			return false
		case ENOTSUP, EINVAL:
			let fm = FileManager.default
			guard (try? fm.attributesOfItem(atPath: path)) == nil else { return false }
			try fm.moveItem(atPath: staging, toPath: path)
			return true
		default:
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t place \((path as NSString).lastPathComponent): "
					+ String(cString: strerror(code)))
		}
	}

	// Crash cleanup for the staged copies (throw and cancel clean up in-process): remove
	// abandoned staging files. Callers guard liveness — nothing may be importing into
	// vmDir when this runs (the daemon sweeps at startup, before any request dispatches,
	// and skips every VM whose vmhost socket answers).
	nonisolated static func sweepStaleStaging(vmDir: String) {
		let fm = FileManager.default
		for entry in (try? fm.contentsOfDirectory(atPath: vmDir)) ?? []
			where entry.hasPrefix(stagingPrefix) {
			try? fm.removeItem(atPath: vmDir + "/" + entry)
			MachmanLogger.log(.log, "removed interrupted disk-import staging \(entry)")
		}
	}
}
