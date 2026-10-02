//
//  SafeSaveDisks.swift
//  MachmanCore
//
//  Save as New VM's disk hand-over (C5). A safe run writes its UNSAFE disks directly: the
//  shadow references the original's storage raws. When the run is saved as a new VM those
//  files move into the saved VM's folder and become its own storage disks, and the
//  original keeps them as references — so deleting the original never destroys the saved
//  VM's data, and the cross-VM guards (DiskReferences) protect the original's use of them.
//  Planning and config rewriting here; VMRegistry.promoteRestrictedVM does the moves.
//

import Foundation
import MachmanAPI

// One disk the run wrote directly: the original's `<storage>.raw`, moving into the saved
// VM's folder as `<target>.raw`.
struct DirectDiskMove: Equatable {
	let storage: String   // the original's storage disk name
	let size: UInt64      // its recorded size, which the saved VM's entry keeps
	let target: String    // the saved VM's storage name: `storage`, or the first free "-<k>"

	var sourceFile: String { storage + ".raw" }
	var targetFile: String { target + ".raw" }

	// What moves, and under which names. A run entry moves when it is enabled, references
	// a storage raw the original's config owns and that file exists; external files and
	// isos never move. A disabled entry was never attached, so the run never wrote it: it
	// stays a reference into the original's folder, which the cross-VM guards keep (C19).
	// A name taken in the saved folder — a file there or a storage disk of the run — gets
	// the first free "<n>-<k>" (k = 2, 3, …), compared case-insensitively like the volume.
	static func plan(
		run: VMConfig, original: VMConfig, originalDir: String, savedFiles: Set<String>,
		fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
	) -> [DirectDiskMove] {
		let dir = (originalDir as NSString).standardizingPath
		var taken = Set(savedFiles.filter { $0.hasSuffix(".raw") }
			.map { String($0.dropLast(4)).lowercased() })
		for disk in run.disks {
			if case .storage(let name, _) = disk.kind { taken.insert(name.lowercased()) }
		}
		var moves: [DirectDiskMove] = []
		for disk in run.disks {
			guard disk.enabled, case .fromUrl(let url) = disk.kind else { continue }
			let path = (url.path as NSString).standardizingPath
			let file = (path as NSString).lastPathComponent
			guard (path as NSString).deletingLastPathComponent == dir, file.hasSuffix(".raw")
			else { continue }
			let storage = String(file.dropLast(4))
			guard !moves.contains(where: { $0.storage == storage }),
				let size = original.storageSize(of: storage), fileExists(path) else { continue }
			var target = storage
			var k = 2
			while taken.contains(target.lowercased()) {
				target = "\(storage)-\(k)"
				k += 1
			}
			taken.insert(target.lowercased())
			moves.append(DirectDiskMove(storage: storage, size: size, target: target))
		}
		return moves
	}
}

extension DirectDiskMove {
	// The one warning a save that moved disks raises: otherwise the first sign is a refusal
	// when the user later deletes the saved VM.
	static func handOverWarning(
		_ moves: [DirectDiskMove], original: String, saved: String
	) -> String? {
		guard !moves.isEmpty else { return nil }
		let files = moves.map(\.targetFile).joined(separator: ", ")
		return moves.count == 1
			? "\(original)'s disk \(files) now lives in \(saved)'s folder; \(saved) can't be "
				+ "deleted while \(original) uses it"
			: "\(original)'s disks \(files) now live in \(saved)'s folder; \(saved) can't be "
				+ "deleted while \(original) uses them"
	}
}

extension VMConfig {
	fileprivate func storageSize(of storage: String) -> UInt64? {
		for disk in disks {
			if case .storage(storage, let size) = disk.kind { return size }
		}
		return nil
	}

	// The saved VM's side: each moved reference becomes its own storage disk. The entry's
	// safe and enabled flags stay.
	func adoptMovedDisks(_ moves: [DirectDiskMove], from originalDir: String) {
		let dir = (originalDir as NSString).standardizingPath
		for index in disks.indices {
			guard case .fromUrl(let url) = disks[index].kind else { continue }
			let path = (url.path as NSString).standardizingPath
			guard let move = moves.first(where: { dir + "/" + $0.sourceFile == path })
			else { continue }
			disks[index].kind = .storage(move.target, move.size)
		}
	}

	// The original's side: each moved storage disk becomes a reference to its file in the
	// saved VM's folder. The entry's safe and enabled flags stay.
	func referenceMovedDisks(_ moves: [DirectDiskMove], in savedDir: String) {
		for index in disks.indices {
			guard case .storage(let name, _) = disks[index].kind,
				let move = moves.first(where: { $0.storage == name }) else { continue }
			disks[index].kind = .fromUrl(URL(fileURLWithPath: savedDir + "/" + move.targetFile))
		}
	}
}

// What promotion changes on the live config, so a failed save restores the run exactly.
// Lists every field promoteRestrictedVM writes — keep the two in step.
struct PromotionSnapshot {
	private let name: String
	private let created: Date
	private let totalRuntimeSeconds: Double
	private let disks: [VMDisk]
	private let boot: BootConfig
	private let kernelSettings: LinuxKernelBoot?
	private let ssh: SSHConfig?
	private let setup: GuestSetupConfig?
	private let macAddress: String?

	init(_ config: VMConfig) {
		name = config.name
		created = config.created
		totalRuntimeSeconds = config.totalRuntimeSeconds
		disks = config.disks
		boot = config.boot
		kernelSettings = config.kernelSettings
		ssh = config.ssh
		setup = config.setup
		macAddress = config.macAddress
	}

	func restore(_ config: VMConfig) {
		config.name = name
		config.created = created
		config.totalRuntimeSeconds = totalRuntimeSeconds
		config.disks = disks
		config.boot = boot
		config.kernelSettings = kernelSettings
		config.ssh = ssh
		config.setup = setup
		config.macAddress = macAddress
	}
}
