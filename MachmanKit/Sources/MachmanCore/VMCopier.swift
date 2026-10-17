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
	// Test seam: false takes the byte-copy path a volume without clonefile(2) takes (exFAT,
	// HFS+, network shares), on any volume.
	var allowClone: Bool = true
}

enum VMCopier {
	static let stagingPrefix = ".machman-copy-"
	// The install state a copy of a not-yet-installed Mac starts in (C10).
	static let unfinishedInstallNote =
		"Duplicated before macOS was installed"

	// Never travel: config is re-encoded; restore.ipsw is an install artifact that only
	// survives crashes; the guest share (payload + report drop-box) exists only while the VM
	// runs — teardown removes it, so one here is a crash leftover, and its report would be
	// ingested at the copy's first boot as the copy's own (C7). The next start rebuilds it.
	private static let alwaysSkipped: Set<String> = [
		"config", MacInstaller.restoreImageFileName, GuestInstallerWriter.payloadRootName,
	]

	// A fresh copy also drops the identity files: vm_identifier is lazily recreated on boot,
	// mac_machine_id is minted below (the installer is its only other creator — omitting it
	// would make a macOS copy unbootable). An impersonating shadow carries both verbatim —
	// the copy IS the VM, and the original cannot run concurrently. The fresh copy leaves
	// the per-VM ssh dir too (C14): its keypair is the source's (until the copy's first
	// payload mints its own, `ssh <copy>` would log in with the source's key) and its
	// known_hosts pin is keyed to the source's alias.
	private static func skippedFiles(for request: VMCopyRequest) -> Set<String> {
		switch request.identity {
		case .fresh: return alwaysSkipped.union(["vm_identifier", "mac_machine_id", "ssh"])
		case .impersonate: return alwaysSkipped
		}
	}

	// The source's serial session output (C9): the per-port logs VMConfig.serialLogURL names
	// "serial-<kind><index>.log", and the pre-1.0.3 file-backed "console.log". A fresh copy
	// starts with none; a shadow keeps them — an append-mode log goes on where the VM's left.
	static func isSerialLog(_ entry: String) -> Bool {
		if entry == "console.log" { return true }
		for kind in [SerialPortKind.console, .uart] {
			let prefix = "serial-\(kind.rawValue)"
			guard entry.hasPrefix(prefix), entry.hasSuffix(".log") else { continue }
			let index = entry.dropFirst(prefix.count).dropLast(".log".count)
			if !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
		}
		return false
	}

	// Returns the destination directory path.
	@discardableResult
	nonisolated static func copy(_ request: VMCopyRequest) throws -> String {
		let fm = FileManager.default
		// The name rules are the callers'; this only makes sure the copy lands inside
		// destinationParent. Safe-run shadows reuse the VM's own (legacy) name as is.
		guard !request.newName.isEmpty, !request.newName.contains("/"),
			request.newName != ".", request.newName != ".." else {
			throw MachmanError(
				code: .invalidArgument,
				message: "\u{201C}\(request.newName)\u{201D} can’t name a VM folder")
		}
		let src = request.sourceDir
		let dst = request.destinationParent + "/" + request.newName
		guard fm.fileExists(atPath: src + "/config") else {
			throw MachmanError(code: .notFound, message: "No VM folder at \(src)")
		}
		guard !fm.fileExists(atPath: dst) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "A VM named \u{201C}\(request.newName)\u{201D} already exists")
		}
		let config: VMConfig
		do {
			config = try JSONDecoder().decode(
				VMConfig.self, from: try Data(contentsOf: URL(fileURLWithPath: src + "/config")))
		} catch {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t read the settings of \((src as NSString).lastPathComponent): "
					+ MachmanError.userMessage(for: error))
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
					code: .alreadyExists,
					message: "A VM named \u{201C}\(request.newName)\u{201D} already exists")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t copy \(request.newName): "
					+ MachmanError.userMessage(for: error))
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
				// The safe-run mechanism: same entry, now pointing at the real file. A disabled
				// one stays disabled: the run must not attach what the VM would not (C19).
				disks.append(disk.withKind(.fromUrl(URL(fileURLWithPath: src + "/\(name).raw"))))
			case (_, .omit):
				continue
			case (.fromUrl(let url), .clone):
				// A cloned external image becomes an OWNED storage disk — the only shape
				// whose path follows the directory through shadow runs and promotion.
				let size = fileSize(atPath: url.path) ?? 0
				let name = storageName(for: url, taken: takenNames)
				takenNames.insert(name)
				externalClones.append((url.path, "\(name).raw", size))
				disks.append(disk.withKind(.storage(name, size)))
			case (.fromUrl, _), (.iso, _):
				// Referenced entries carry verbatim; the file stays put. An OWNED iso
				// (imported/promoted into the dir) travels with the sidecar walk, and
				// rewriteOwnedPaths (step 4) re-points its entry at the copy.
				disks.append(disk)
			}
		}
		// 2. Sidecars: everything else travels except the skip list and .raw files not chosen
		// above (an orphaned .raw is not part of the VM).
		let skipped = skippedFiles(for: request)
		var travel: [(name: String, size: UInt64)] = []
		for entry in try fm.contentsOfDirectory(atPath: src).sorted() {
			if skipped.contains(entry) { continue }
			if entry.hasSuffix(".raw") && !clonedRaws.contains(entry) { continue }
			if case .fresh = request.identity, isSerialLog(entry) { continue }
			guard let size = travelSize(atPath: src + "/" + entry) else {
				MachmanLogger.log(.log,
					"copying \(config.name): left out \(entry) (not a file or folder)")
				continue
			}
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
				isCancelled: request.isCancelled, allowClone: request.allowClone)
			copiedBase += file.size
			if clonedRaws.contains(file.name) {
				excludeFromBackup(path: staging + "/" + file.name)
			}
		}
		for clone in externalClones {
			try cloneOrCopy(
				clone.source, staging + "/" + clone.file,
				base: copiedBase, size: clone.size, throttle: throttle,
				isCancelled: request.isCancelled, allowClone: request.allowClone)
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
		// Owned paths are absolute — re-point the kernel, the initramfs and owned isos at the
		// copies the sidecar walk brought along, or the new VM keeps booting the SOURCE's
		// files (and dies with them). Both identities: a shadow must be self-contained too, so
		// that promotion only ever re-points within its own directory. fromUrl references
		// keep pointing at the source (the .copied rule).
		config.rewriteOwnedPaths(
			fromDir: src, toDir: request.destinationParent + "/" + request.newName, .copied)
		if request.regenerateMAC {
			config.macAddress = VZMACAddress.randomLocallyAdministered().string
		}
		// A fresh copy is a new VM: no run history, and no ssh INSTANCE identity — the
		// alias, lease, pinned host key, reverse grant and cached marker all name the
		// source's ~/.ssh footprint (carrying them makes `ssh <copy>` land in the source).
		// An impersonating shadow keeps both — it presents AS that VM, and the copy-back at
		// stop relies on the totals starting from the real values.
		if case .fresh = request.identity {
			config.created = Date()
			config.lastRan = nil
			config.totalRuntimeSeconds = 0
			config.dropAlias()
			config.ssh?.resetInstanceIdentity()
			// The copy takes a new name: its default alias yields to every VM already in
			// the library, the source included (SSHAliasAssignment).
			if let alias = SSHAliasAssignment.yieldingAlias(
				for: request.newName,
				among: SSHAliasAssignment.claims(inLibrary: request.destinationParent)) {
				var state = config.ssh ?? SSHConfig()
				state.alias = alias
				config.ssh = state
			}
			// Decision 12: the copy serves the installer at its first boot, like a new guest
			// — its script will say "looks cloned … treating it as new" (C14).
			config.setup?.resetForFreshIdentity()
			// S57: its payloads tell its script it is a copy (COPY_OF), so the first run
			// renews the identity the disk carries even where the source never ran Guest
			// Setup and left no state to show it. A source that never started has none.
			if let source = SSHSetupInstaller.existingMarker(inVMDir: src) {
				var state = config.setup ?? GuestSetupConfig()
				state.copyOf = source
				config.setup = state
			}
			// C10: a Mac whose install never finished copies as one that needs installing,
			// in its own words. "installing" would claim an install ran in the COPY's
			// directory (read back as "interrupted"), and a carried failure reason would
			// describe the source's attempt.
			if case .macOS(var mac) = config.boot, mac.installState != .installed {
				mac.installState = .failed(Self.unfinishedInstallNote)
				config.boot = .macOS(mac)
			}
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
		// Imported names follow the disk-name rule like typed ones (".hidden.raw" → hidden).
		let base = NameRule.diskName.suggestion(
			from: url.deletingPathExtension().lastPathComponent, fallback: "disk")
		guard taken.contains(base) else { return base }
		var n = 2
		while taken.contains("\(base)-\(n)") { n += 1 }
		return "\(base)-\(n)"
	}

	private static func defaultPolicy(for disk: VMDisk) -> VMCopyRequest.DiskPolicy {
		if case .storage = disk.kind { return .clone }
		return .reference
	}

	private enum EntryKind { case file, directory, link }

	// What a directory entry is, links not followed; nil for what never travels — a socket
	// (a legacy vm.sock: copyfile refuses it with ENOTSUP, which aborted the whole copy), a
	// FIFO (opening one blocks) or a device.
	private static func entryKind(atPath path: String) -> EntryKind? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
			let type = attributes[.type] as? FileAttributeType else { return nil }
		switch type {
		case .typeRegular: return .file
		case .typeDirectory: return .directory
		case .typeSymbolicLink: return .link
		default: return nil
		}
	}

	// The bytes one sidecar entry carries, for progress: a file's size, a directory's files
	// summed (a directory's own size is its entry table), 0 for a link. nil = never travels.
	static func travelSize(atPath path: String) -> UInt64? {
		switch entryKind(atPath: path) {
		case .file:
			return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64)
				.flatMap { $0 } ?? 0
		case .directory:
			let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
			return children.reduce(0) { $0 + (travelSize(atPath: path + "/" + $1) ?? 0) }
		case .link:
			return 0
		case nil:
			return nil
		}
	}

	// clonefile(2) first — instant, the common same-volume case, and a whole directory tree
	// at once. The copyfile fallback carries the per-chunk progress callback for the copies
	// that are actually slow; a directory falls back to copyTree.
	fileprivate static func cloneOrCopy(
		_ src: String, _ dst: String, base: UInt64, size: UInt64,
		throttle: ProgressThrottle, isCancelled: (@Sendable () -> Bool)?,
		allowClone: Bool = true
	) throws {
		if isCancelled?() == true {
			throw MachmanError(code: .ioFailure, message: "The copy was canceled")
		}
		if allowClone, clonefile(src, dst, 0) == 0 {
			throttle.report(base + size)
			return
		}
		if entryKind(atPath: src) == .directory {
			try copyTree(src, dst, base: base, throttle: throttle, isCancelled: isCancelled)
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
		// Typed first: the bare function name is a Swift closure value (two words), and the
		// bit cast of THAT trapped every byte copy — the C pointer is one word.
		let callback: copyfile_callback_t = copyStatusCallback
		copyfile_state_set(
			state, UInt32(COPYFILE_STATE_STATUS_CB),
			unsafeBitCast(callback, to: UnsafeRawPointer.self))
		guard copyfile(src, dst, state, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
			if context.canceled {
				throw MachmanError(code: .ioFailure, message: "The copy was canceled")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t copy \((src as NSString).lastPathComponent): "
					+ String(cString: strerror(errno)))
		}
		throttle.report(base + size)
	}

	// The byte copy of a directory (C6), entry by entry: copyfile without COPYFILE_RECURSIVE
	// makes only the directory itself (its mode, ACL and xattrs — an empty shell), and with
	// it the walk stops at the first socket. Files and subdirectories go through
	// cloneOrCopy with progress, links travel as links (as clonefile carries them), and
	// sockets, FIFOs and devices are left out.
	private static func copyTree(
		_ src: String, _ dst: String, base: UInt64,
		throttle: ProgressThrottle, isCancelled: (@Sendable () -> Bool)?
	) throws {
		guard copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t copy \((src as NSString).lastPathComponent): "
					+ String(cString: strerror(errno)))
		}
		var offset = base
		for child in try FileManager.default.contentsOfDirectory(atPath: src).sorted() {
			let from = src + "/" + child
			let to = dst + "/" + child
			switch entryKind(atPath: from) {
			case .file, .directory:
				let size = travelSize(atPath: from) ?? 0
				try cloneOrCopy(
					from, to, base: offset, size: size, throttle: throttle,
					isCancelled: isCancelled, allowClone: false)
				offset += size
			case .link:
				let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC)
				guard copyfile(from, to, nil, flags) == 0 else {
					throw MachmanError(
						code: .ioFailure,
						message: "Couldn’t copy \((from as NSString).lastPathComponent): "
							+ String(cString: strerror(errno)))
				}
			case nil:
				MachmanLogger.log(.log, "copy left out \(from) (not a file or folder)")
			}
		}
	}
}

extension GuestSetupConfig {
	// What a fresh machine identity (vm.copy) forgets of guest setup: the last run, which the
	// source's script did under the source's marker — the copy's own script treats those
	// artifacts as another VM's. With `installed` gone the copy serves the installer until
	// its own first report (servesSetupPayload). The guest OS facts stay: they describe the
	// cloned disk.
	mutating func resetForFreshIdentity() {
		installed = nil
		reinstallRequested = nil
		lastReportAt = nil
		scriptVersion = nil
		scriptCksum = nil
		lastRunStatus = nil
		lastRunNote = nil
		lastTransport = nil
		errors = []
		notes = []
		features = []
		consoles = []
		automounts = []
	}
}

// Single-file transfer with the copier's clone-first mechanics and throttled progress —
// the engine under disk imports and promotes.
enum FileTransfer {
	// allowClone false (tests) takes the byte copy a cross-volume import takes.
	nonisolated static func copy(
		src: String, dst: String,
		progress: (@Sendable (UInt64, UInt64) -> Void)? = nil,
		isCancelled: (@Sendable () -> Bool)? = nil,
		allowClone: Bool = true
	) throws {
		let size = fileSize(atPath: src) ?? 0
		let throttle = ProgressThrottle(total: size, report: progress)
		try VMCopier.cloneOrCopy(
			src, dst, base: 0, size: size, throttle: throttle, isCancelled: isCancelled,
			allowClone: allowClone)
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
