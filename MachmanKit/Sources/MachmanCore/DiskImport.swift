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
	nonisolated static func importFile(
		src: String, vmDir: String, takenStorageNames: Set<String>,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil
	) throws -> VMDisk {
		let fm = FileManager.default
		guard fm.fileExists(atPath: src) else {
			throw MachmanError(code: .notFound, message: "no file at \(src)")
		}
		let size = (try? fm.attributesOfItem(atPath: src)[.size] as? UInt64)
			.flatMap { $0 } ?? 0
		switch DiskFormat.sniff(path: src) {
		case .qcow:
			throw MachmanError(
				code: .invalidArgument,
				message: "qcow2 images are not supported by Virtualization.framework — "
					+ "convert to raw first (qemu-img convert -O raw)")
		case .unreadable:
			throw MachmanError(code: .invalidArgument, message: "cannot read \(src)")
		case .raw:
			guard size > 0, size % 512 == 0 else {
				throw MachmanError(
					code: .invalidArgument,
					message: "raw disk images must be a non-empty multiple of 512 bytes "
						+ "(\(src) is \(size))")
			}
			var taken = takenStorageNames
			for entry in (try? fm.contentsOfDirectory(atPath: vmDir)) ?? []
				where entry.hasSuffix(".raw") {
				taken.insert(String(entry.dropLast(4)))
			}
			let name = VMCopier.storageName(for: URL(fileURLWithPath: src), taken: taken)
			let dst = vmDir + "/\(name).raw"
			try stagedCopy(
				src: src, dst: dst, vmDir: vmDir,
				progress: progress, isCancelled: isCancelled)
			return VMDisk(kind: .storage(name, size))
		case .iso:
			let base = URL(fileURLWithPath: src).lastPathComponent
			var fileName = base
			var n = 2
			while fm.fileExists(atPath: vmDir + "/" + fileName) {
				let stem = URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent
				let ext = URL(fileURLWithPath: base).pathExtension
				fileName = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
				n += 1
			}
			let dst = vmDir + "/" + fileName
			try stagedCopy(
				src: src, dst: dst, vmDir: vmDir,
				progress: progress, isCancelled: isCancelled)
			return VMDisk(kind: .iso(URL(fileURLWithPath: dst)))
		}
	}

	// Copy via a hidden staged sibling and rename into place: a throw or cancel mid-copy
	// never leaves a partial file under the final name, and a crash leaves only a staged
	// name sweepStaleStaging recognizes. The transfer is injectable because the real
	// failure-after-partial-write cannot be reproduced on one APFS volume (clonefile is
	// atomic there); default is the clone-first engine.
	nonisolated static func stagedCopy(
		src: String, dst: String, vmDir: String,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil,
		transfer: ((String, String) throws -> Void)? = nil
	) throws {
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
			try fm.moveItem(atPath: staging, toPath: dst)
		} catch {
			try? fm.removeItem(atPath: staging)
			throw error
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
