//
//  VMCopier.swift
//  MachmanCore
//
//  Duplicates one VM directory into a sibling: the config is decoded, patched, and re-encoded
//  with the PERSISTENCE coder (plain JSONEncoder, .prettyPrinted — MachmanWire's ISO dates
//  would make the copy unreadable to VMConfig.load); disks are cloned, referenced, or omitted
//  per policy. Operates on explicit directories — no machmanVMDir dependency — so the daemon
//  runs it detached and tests run it on bare temp dirs. Phase 6 reuses it for safe-run shadows.
//
//  Crash-safe by staging: everything lands in a hidden sibling directory that is renamed into
//  place last, so an interrupted copy leaves only a dot-directory the registry scan skips —
//  and the final rename doubles as the winner-takes-the-name arbiter against concurrent
//  create/rename landing on the same name.
//

import Foundation
import Virtualization
import MachmanAPI

struct VMCopyRequest: Sendable {
	enum DiskPolicy: Sendable {
		case clone       // copy the backing file into the new VM (APFS clone when possible)
		case reference   // keep a disk entry pointing at the SOURCE file (fromUrl)
		case omit        // no disk entry, no file
	}
	enum GuestKind: Sendable {
		case generic
		case macOS       // carry hardware model + aux storage; identity below decides minting
	}
	enum Identity: Sendable {
		case fresh        // a new VM: fresh identity files, reset history (vm.copy)
		case impersonate  // a safe-run shadow: the copy IS the VM — identity + history travel
	}

	var sourceDir: String          // …/VMs/<name>
	var destinationParent: String  // …/VMs
	var newName: String
	// Keyed by VMDisk.id; unlisted disks default by kind: storage → clone, else reference.
	var diskPolicies: [String: DiskPolicy] = [:]
	var includedMountIDs: Set<String>? = nil   // nil = keep every mount
	var regenerateMAC: Bool = true
	var guestKind: GuestKind = .generic
	var identity: Identity = .fresh
	// (copiedBytes, totalBytes), already throttled. Total is the sum of traveling files.
	var progress: (@Sendable (UInt64, UInt64) -> Void)? = nil
	// Checked between chunks; returning true aborts with ioFailure. No UI drives it yet.
	var isCancelled: (@Sendable () -> Bool)? = nil
}

enum VMCopier {
	static let stagingPrefix = ".machman-copy-"

	// Never travel: config is re-encoded; console.log is session output; restore.ipsw is an
	// install artifact that only survives crashes.
	private static let alwaysSkipped: Set<String> =
		["config", "console.log", "restore.ipsw"]

	// A fresh copy also drops the identity files: vm_identifier is lazily recreated on boot,
	// mac_machine_id is minted below (the installer is its only other creator — omitting it
	// would make a macOS copy unbootable). An impersonating shadow carries both verbatim —
	// the copy IS the VM, and the original cannot run concurrently.
	private static func skippedFiles(for request: VMCopyRequest) -> Set<String> {
		switch request.identity {
		case .fresh: return alwaysSkipped.union(["vm_identifier", "mac_machine_id"])
		case .impersonate: return alwaysSkipped
		}
	}

	// Returns the destination directory path.
	@discardableResult
	nonisolated static func copy(_ request: VMCopyRequest) throws -> String {
		let fm = FileManager.default
		let src = request.sourceDir
		let dst = request.destinationParent + "/" + request.newName
		guard fm.fileExists(atPath: src + "/config") else {
			throw MachmanError(code: .notFound, message: "no VM directory at \(src)")
		}
		guard !fm.fileExists(atPath: dst) else {
			throw MachmanError(
				code: .alreadyExists, message: "'\(request.newName)' already exists")
		}
		let config: VMConfig
		do {
			config = try JSONDecoder().decode(
				VMConfig.self, from: try Data(contentsOf: URL(fileURLWithPath: src + "/config")))
		} catch {
			throw MachmanError(code: .ioFailure, message: "unreadable config at \(src): \(error)")
		}
		let staging = request.destinationParent + "/" + stagingPrefix + UUID().uuidString
		do {
			try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
			try populate(staging: staging, src: src, config: config, request: request)
			try fm.moveItem(atPath: staging, toPath: dst)
		} catch {
			try? fm.removeItem(atPath: staging)
			if let machman = error as? MachmanError { throw machman }
			if fm.fileExists(atPath: dst) {
				// The name appeared while we copied; the rename lost the race.
				throw MachmanError(
					code: .alreadyExists, message: "'\(request.newName)' already exists")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "copying \(request.newName): \(error.localizedDescription)")
		}
		return dst
	}

	private static func populate(
		staging: String, src: String, config: VMConfig, request: VMCopyRequest
	) throws {
		let fm = FileManager.default
		// 1. Disks: transform the config entries; note which backing files travel. External
		// clone names must dodge existing storage names AND every raw already in the source
		// dir (a stray orphan raw would otherwise collide in staging).
		var clonedRaws: Set<String> = []
		var externalClones: [(source: String, file: String, size: UInt64)] = []
		var takenNames: Set<String> = Set(config.disks.compactMap {
			if case .storage(let name, _) = $0.kind { return name }
			return nil
		})
		for entry in (try? fm.contentsOfDirectory(atPath: src)) ?? []
			where entry.hasSuffix(".raw") {
			takenNames.insert(String(entry.dropLast(4)))
		}
		var disks: [VMDisk] = []
		for disk in config.disks {
			let policy = request.diskPolicies[disk.id] ?? defaultPolicy(for: disk)
			switch (disk.kind, policy) {
			case (.storage(let name, _), .clone):
				clonedRaws.insert("\(name).raw")
				disks.append(disk)
			case (.storage(let name, _), .reference):
				// The safe-run mechanism: same entry, now pointing at the real file.
				disks.append(VMDisk(
					kind: .fromUrl(URL(fileURLWithPath: src + "/\(name).raw")),
					safe: disk.safe))
			case (_, .omit):
				continue
			case (.fromUrl(let url), .clone):
				// A cloned external image becomes an OWNED storage disk — the only shape
				// whose path follows the directory through shadow runs and promotion.
				let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64)
					.flatMap { $0 } ?? 0
				let name = storageName(for: url, taken: takenNames)
				takenNames.insert(name)
				externalClones.append((url.path, "\(name).raw", size))
				disks.append(VMDisk(kind: .storage(name, size), safe: disk.safe))
			case (.iso(let url), _) where url.path.hasPrefix(src + "/"):
				// An OWNED iso (imported/promoted into the dir) travels with the sidecar
				// walk — its entry must follow the directory or the copy points back at
				// the source. fromUrl references deliberately keep pointing at the source.
				let relative = String(url.path.dropFirst(src.count + 1))
				let final = request.destinationParent + "/" + request.newName
				disks.append(VMDisk(
					kind: .iso(URL(fileURLWithPath: final + "/" + relative)),
					safe: disk.safe))
			case (.fromUrl, _), (.iso, _):
				disks.append(disk)   // referenced entries carry verbatim; the file stays put
			}
		}
		// 2. Sidecars: everything else travels except the skip list and .raw files not chosen
		// above (an orphaned .raw is not part of the VM).
		let skipped = skippedFiles(for: request)
		var travel: [(name: String, size: UInt64)] = []
		for entry in try fm.contentsOfDirectory(atPath: src).sorted() {
			if skipped.contains(entry) { continue }
			if entry.hasSuffix(".raw") && !clonedRaws.contains(entry) { continue }
			let size = (try? fm.attributesOfItem(atPath: src + "/" + entry)[.size] as? UInt64)
				.flatMap { $0 } ?? 0
			travel.append((entry, size))
		}
		let totalBytes = travel.reduce(0) { $0 + $1.size }
			+ externalClones.reduce(0) { $0 + $1.size }
		let throttle = ProgressThrottle(total: totalBytes, report: request.progress)
		var copiedBase: UInt64 = 0
		for file in travel {
			try cloneOrCopy(
				src + "/" + file.name, staging + "/" + file.name,
				base: copiedBase, size: file.size, throttle: throttle,
				isCancelled: request.isCancelled)
			copiedBase += file.size
			if clonedRaws.contains(file.name) {
				excludeFromBackup(path: staging + "/" + file.name)
			}
		}
		for clone in externalClones {
			try cloneOrCopy(
				clone.source, staging + "/" + clone.file,
				base: copiedBase, size: clone.size, throttle: throttle,
				isCancelled: request.isCancelled)
			copiedBase += clone.size
			excludeFromBackup(path: staging + "/" + clone.file)   // owned storage now
		}
		throttle.finish(copiedBase)
		// 3. macOS identity: hardware model and aux storage traveled above. A FRESH copy
		// mints its own machine id (two guests sharing one confuse the framework and the
		// host cap); an impersonating shadow already carried the original's.
		if case .fresh = request.identity, case .macOS = request.guestKind {
			try VMConfig.mintMacMachineIdentifier(at: staging + "/mac_machine_id")
		}
		// 4. Patch and write the config last, with the persistence coder.
		config.name = request.newName
		config.disks = disks
		if let included = request.includedMountIDs {
			config.mountPoints.removeAll { !included.contains($0.id.uuidString) }
		}
		if request.regenerateMAC {
			config.macAddress = VZMACAddress.randomLocallyAdministered().string
		}
		// A fresh copy is a new VM: no run history. An impersonating shadow keeps the real
		// VM's history — it presents AS that VM, and the copy-back at stop relies on the
		// totals starting from the real values.
		if case .fresh = request.identity {
			config.created = Date()
			config.lastRan = nil
			config.totalRuntimeSeconds = 0
		}
		// In both modes autostart must be an explicit opt-in: an inherited flag would
		// install a launch agent nobody asked for (a promoted shadow becomes a real VM).
		config.startPolicy.autostart = false
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		try (try encoder.encode(config))
			.write(to: URL(fileURLWithPath: staging + "/config"), options: .atomic)
	}

	// "ubuntu-cloud.img" → "ubuntu-cloud", uniquified with -2, -3… against taken names.
	// Internal: disk imports (phase 6 disk-ownership track) reuse it.
	static func storageName(for url: URL, taken: Set<String>) -> String {
		var base = url.deletingPathExtension().lastPathComponent
		if base.isEmpty { base = "disk" }
		guard taken.contains(base) else { return base }
		var n = 2
		while taken.contains("\(base)-\(n)") { n += 1 }
		return "\(base)-\(n)"
	}

	private static func defaultPolicy(for disk: VMDisk) -> VMCopyRequest.DiskPolicy {
		if case .storage = disk.kind { return .clone }
		return .reference
	}

	// clonefile(2) first — instant, and the common same-volume case. The copyfile fallback
	// carries the per-chunk progress callback for the copies that are actually slow.
	fileprivate static func cloneOrCopy(
		_ src: String, _ dst: String, base: UInt64, size: UInt64,
		throttle: ProgressThrottle, isCancelled: (@Sendable () -> Bool)?
	) throws {
		if isCancelled?() == true {
			throw MachmanError(code: .ioFailure, message: "copy canceled")
		}
		if clonefile(src, dst, 0) == 0 {
			throttle.report(base + size)
			return
		}
		let context = CopyFileContext(
			base: base, throttle: throttle, isCancelled: isCancelled ?? { false })
		let state = copyfile_state_alloc()
		defer { copyfile_state_free(state) }
		let unmanaged = Unmanaged.passRetained(context)
		defer { unmanaged.release() }
		copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
		copyfile_state_set(
			state, UInt32(COPYFILE_STATE_STATUS_CB),
			unsafeBitCast(copyStatusCallback, to: UnsafeRawPointer.self))
		guard copyfile(src, dst, state, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
			if context.canceled {
				throw MachmanError(code: .ioFailure, message: "copy canceled")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "copying \(src): \(String(cString: strerror(errno)))")
		}
		throttle.report(base + size)
	}
}

// Single-file transfer with the copier's clone-first mechanics and throttled progress —
// the engine under disk imports and promotes.
enum FileTransfer {
	nonisolated static func copy(
		src: String, dst: String,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil
	) throws {
		let size = (try? FileManager.default.attributesOfItem(atPath: src)[.size] as? UInt64)
			.flatMap { $0 } ?? 0
		let throttle = ProgressThrottle(total: size, report: progress)
		try VMCopier.cloneOrCopy(
			src, dst, base: 0, size: size, throttle: throttle, isCancelled: isCancelled)
		throttle.finish(size)
	}
}

// Bytes-based throttle: emit on ≥1% change (or completion) so event streams stay quiet.
private final class ProgressThrottle: @unchecked Sendable {
	private let total: UInt64
	private let callback: (@Sendable (UInt64, UInt64) -> Void)?
	private var lastReported: UInt64 = 0
	private let lock = NSLock()

	init(total: UInt64, report: (@Sendable (UInt64, UInt64) -> Void)?) {
		self.total = total
		self.callback = report
	}

	func report(_ copied: UInt64) {
		guard let callback, total > 0 else { return }
		lock.lock()
		let step = max(total / 100, 1)
		guard copied >= lastReported + step || copied >= total else {
			lock.unlock()
			return
		}
		lastReported = copied
		lock.unlock()
		callback(min(copied, total), total)
	}

	func finish(_ copied: UInt64) {
		guard let callback, total > 0 else { return }
		callback(min(copied, total), total)
	}
}

private final class CopyFileContext: @unchecked Sendable {
	let base: UInt64
	let throttle: ProgressThrottle
	let isCancelled: @Sendable () -> Bool
	var canceled = false

	init(base: UInt64, throttle: ProgressThrottle, isCancelled: @escaping @Sendable () -> Bool) {
		self.base = base
		self.throttle = throttle
		self.isCancelled = isCancelled
	}
}

// C callback: no captures allowed — context rides in the state's CTX slot.
private func copyStatusCallback(
	_ what: Int32, _ stage: Int32, _ state: copyfile_state_t?,
	_ src: UnsafePointer<CChar>?, _ dst: UnsafePointer<CChar>?, _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
	guard let ctx else { return COPYFILE_CONTINUE }
	let context = Unmanaged<CopyFileContext>.fromOpaque(ctx).takeUnretainedValue()
	if context.isCancelled() {
		context.canceled = true
		return COPYFILE_QUIT
	}
	if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
		var copied: off_t = 0
		if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
			context.throttle.report(context.base + UInt64(max(copied, 0)))
		}
	}
	return COPYFILE_CONTINUE
}
