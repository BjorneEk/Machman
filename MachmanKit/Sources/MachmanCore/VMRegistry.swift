//
//  VMRegistry.swift
//  Machman
//
//  The engine facade: which VMs exist, and which run in THIS process. Owns the event bus and
//  the window presenter; enforces the cross-VM invariants it can see (unique names, no
//  delete/rename of a VM running here). In the daemon no VM runs in-process, so those runtime
//  checks are inert there: the router's residence (RoutingMachman) decides what runs. This is
//  what LocalMachman wraps for the API.
//

import Foundation
import AppKit
import MachmanAPI

// One managed VM: persisted config plus (when running) its live runtime. Class identity is the
// UI selection identity; the registry guarantees one instance per VM.
@MainActor
public final class VirtualMachine: NSObject, Identifiable {
	let config: VMConfig
	var runtime: VMRuntime?
	var previewImage: NSImage?
	private weak var events: EventBus?

	init(config: VMConfig, events: EventBus? = nil) {
		self.config = config
		self.events = events
		super.init()
	}

	public var name: String { config.name }
	public var state: VMState { runtime?.state ?? .stopped }

	func updatePreview(img: NSImage) {
		previewImage = img
	}

	// EventBus routes every log event through MachmanLogger once (the guaranteed sink);
	// subscribers and remote clients get the same line as an event. The ?? arm covers a VM
	// whose bus is gone (mid-teardown).
	func log(error: String) {
		events?.emit(.log(vm: config.name, level: .error, message: error))
			?? MachmanLogger.log(.passiveError, error)
	}

	func log(message: String) {
		events?.emit(.log(vm: config.name, level: .message, message: message))
			?? MachmanLogger.log(.log, message)
	}

	func log(warning: String) {
		events?.emit(.log(vm: config.name, level: .warning, message: warning))
			?? MachmanLogger.log(.passiveWarning, warning)
	}
}

@MainActor
public final class VMRegistry {
	// A windowed start of a display-less VM (a warning: the desktop shows "<VM>: …").
	nonisolated static let headlessStartWarning = "It has no display, so it started headless."

	let events = EventBus()
	let presenter = WindowPresenter()
	private(set) var vms: [String: VirtualMachine] = [:]
	// Sessions live here (not in a view) so a running install keeps its phase and progress
	// when the user navigates away, and a second install of the same VM can't start.
	private var installSessions: [String: InstallSession] = [:]
	// What new install sessions run — a test seam; production installs through MacInstaller.
	var installRunner: InstallSession.Runner = InstallSession.runInstaller
	// Non-nil in a vmhost process: this registry manages exactly that one VM.
	// var: safeSave promotion re-keys the vmhost to the saved VM's name. Internal read —
	// the bootstrap's lifecycle watcher and quit delegate follow it instead of a stale
	// captured launch name.
	private(set) var restrictedName: String?
	// Safe-run vmhosts only: where vm.safeSave promotes the shadow to. nil everywhere else,
	// which is what makes safeSave refusable outside a daemon-spawned safe run; cleared
	// after use so a run promotes at most once.
	private var promotionLibrary: String?
	// Called after a successful promotion (old name, new name): the vmhost moves its socket.
	var onPromoted: ((_ from: String, _ to: String) -> Void)?
	// Save as New VM's one move primitive: renamex_np(RENAME_EXCL) — atomic, same volume
	// only (EXDEV otherwise), and never over an existing entry (plain rename(2) silently
	// replaces an empty directory). Returns 0 or the errno. A test seam.
	var renameExclusive: (String, String) -> Int32 = {
		renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
	}

	public convenience init() {
		self.init(only: nil)
	}

	// `only`: restrict the registry to a single VM (the vmhost case) — the scan ignores every
	// other directory and create() is refused.
	public init(only restrictedName: String?, promotionLibrary: String? = nil) {
		self.restrictedName = restrictedName
		self.promotionLibrary = promotionLibrary
		// The vmhost's own Stop menu and prompts: a refusal goes back to them for an alert, as
		// well as to the log.
		presenter.stopHandler = { [weak self] name, mode in
			guard let self, let vm = self.vms[name] else { return }
			do {
				try await self.stop(vm, mode: mode)
			} catch {
				// An engine refusal already names the VM and says what to do.
				let reason = MachmanError.userMessage(for: error)
				vm.log(error: error is MachmanError ? reason : "Couldn’t stop: \(reason)")
				throw error
			}
		}
		presenter.isRunning = { [weak self] name in
			self?.vms[name]?.state.isRunning ?? false
		}
		presenter.onWindowChanged = { [weak self] in
			self?.events.emit(.listChanged)
		}
		presenter.captureMode = { [weak self] name in
			self?.vms[name]?.runtime?.systemKeyCapture
		}
		presenter.setCaptureMode = { [weak self] name, mode in
			self?.vms[name]?.runtime?.systemKeyCapture = mode
		}
		// Only a vmhost captures, and its registry is restricted to its one VM: that names
		// the VM the warning is about (F6). The raw window id stays in the unified log
		// (WindowPresenter.report); one sentence each, the desktop prefixes the VM's name.
		presenter.onCaptureFailed = { [weak self] failure in
			guard let self else { return }
			let message: String
			switch failure {
			case .windowNotFound:
				message = "Its window isn’t on screen, so the preview is blank."
			case .captureReturnedNothing:
				message = "ScreenCaptureKit returned no image, so the preview is blank."
			case .noPermission:
				// Vmhosts launch as standalone apps, so TCC attributes capture requests to the
				// vmhost app itself — "Machman VM" in System Settings ("Machman VM (Dev)" in
				// dev builds). macOS caches the answer per process, so a fresh grant is
				// invisible until this VM's host process is relaunched.
				message = "Screen Recording is off for Machman VM, so previews are blank: "
					+ "allow it in System Settings › Privacy & Security › Screen Recording, "
					+ "then stop and start this VM."
			}
			self.events.emit(.log(vm: self.restrictedName, level: .warning, message: message))
		}
		scan()
	}

	private func scan() {
		// First run against a fresh library: the directory simply doesn't exist yet.
		try? VMConfig.ensureLibrary()
		let folderURL = URL(fileURLWithPath: machmanVMDir)
		do {
			let contents = try FileManager.default.contentsOfDirectory(
				at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles])
			for url in contents {
				let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
				guard values?.isDirectory ?? false else { continue }
				let name = url.lastPathComponent
				if let only = restrictedName, name != only { continue }
				let config: VMConfig
				do {
					config = try VMConfig.load(name: name)
				} catch {
					// Never swallow this. A directory that won't parse means a VM the user owns
					// has vanished from the app, and silence makes that look like data loss
					// rather than a damaged config file they could restore.
					MachmanLogger.log(.passiveError,
						"skipping '\(name)': its config could not be read: \(error)")
					continue
				}
				// Idempotent, and the only chance images created before this existed ever get
				// marked — which today means all of them.
				config.excludeDiskImagesFromBackup()
				vms[name] = VirtualMachine(config: config, events: events)
			}
		} catch {
			MachmanLogger.log(.passiveError, "error reading machines: \(error)")
		}
	}

	public func list() -> [VirtualMachine] {
		vms.values.sorted {
			$0.config.lastRan ?? .distantPast > $1.config.lastRan ?? .distantPast
		}
	}

	func vm(named name: String) -> VirtualMachine? {
		vms[name]
	}

	// MARK: - Run / stop

	func start(_ vm: VirtualMachine, openWindow: Bool = true) async throws {
		guard vm.runtime == nil else {
			throw MachmanError(
				code: .invalidState, message: "\(vm.config.name) is already running")
		}
		guard !(installSessions[vm.config.name]?.isInstalling ?? false) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(vm.config.name) can’t start while macOS is installing")
		}
		let runtime = VMRuntime(config: vm.config, events: events)
		// Runtime accumulates here and only here — in the process that ran the VM, at teardown,
		// before a vmhost's exit flush. The daemon never accumulates, so adoption cannot
		// double-count.
		let startedAt = Date()
		runtime.onTeardown = { [weak self, weak vm] in
			guard let vm = vm else { return }
			vm.runtime = nil
			vm.config.addRuntime(Date().timeIntervalSince(startedAt))
			self?.presenter.dropWindow(name: vm.config.name)
		}
		vm.runtime = runtime
		do {
			try await runtime.start()
		} catch {
			vm.runtime = nil
			throw error
		}
		try? vm.config.markRan()
		if openWindow, let vz = runtime.vz {
			if vz.graphicsDevices.isEmpty {
				// A windowed start of a display-less VM starts headless and says so —
				// the configured preference is preserved, not silently rewritten.
				events.emit(.log(
					vm: vm.config.name, level: .warning, message: Self.headlessStartWarning))
			} else {
				presenter.openWindow(name: vm.config.name, vz: vz)
			}
		}
	}

	public func stop(_ vm: VirtualMachine, mode: StopMode) async throws {
		guard let runtime = vm.runtime else { return }
		switch mode {
		case .soft:
			try runtime.requestSoftStop()
		case .force:
			try await runtime.forceStop()
			vm.log(message: "VM: \(vm.config.name) stopped successfully.")
		}
	}

	func openWindow(_ vm: VirtualMachine) throws {
		guard let vz = vm.runtime?.vz else {
			throw MachmanError(
				code: .invalidState, message: "\(vm.config.name) is not running")
		}
		guard !vz.graphicsDevices.isEmpty else {
			throw MachmanError(
				code: .invalidState,
				message: "\(vm.config.name) has no display — add one and restart it to use a "
					+ "window")
		}
		presenter.openWindow(name: vm.config.name, vz: vz)
	}

	func closeWindow(_ vm: VirtualMachine) {
		presenter.dropWindow(name: vm.config.name)
	}

	func isWindowOpen(_ vm: VirtualMachine) -> Bool {
		presenter.window(for: vm.config.name) != nil
	}

	func captureImage(name: String) async -> CGImage? {
		await presenter.captureImage(name: name)
	}

	// MARK: - Serial data plane

	// Live per-port endpoints. A serial port's socket and log file exist only while the VM runs
	// in this process (a vmhost), served by its VMRuntime's bridges. The daemon (VM stopped here)
	// reports nil, and the desktop opens the reported socketPath directly.
	func serialSocketPath(vm: VirtualMachine, kind: SerialPortKind, index: Int) -> String? {
		vm.runtime?.serialSocketPath(kind: kind, index: index)
	}

	func serialLogPath(vm: VirtualMachine, kind: SerialPortKind, index: Int) -> String? {
		guard vm.runtime != nil else { return nil }
		let ports = kind == .console ? vm.config.consolePorts : vm.config.uartPorts
		guard ports.indices.contains(index), ports[index].logging.mode != .disabled else {
			return nil
		}
		return vm.config.serialLogURL(kind: kind, index: index).path
	}

	func retuneSerialLogging(
		vm: VirtualMachine, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) {
		vm.runtime?.retuneSerialLogging(kind: kind, index: index, config: config)
	}

	// MARK: - Create / delete / rename

	// "<base>", "<base> 2", "<base> 3", … probed against the in-memory map.
	func uniqueName(base: String) -> String {
		UniqueName.numbered(base) { vms[$0] != nil }
	}

	// vm.safeSave's engine half — vmhost-side ONLY (single-writer: the vmhost moves files it
	// owns). Renames the shadow dir into the library atomically (same volume by
	// construction, refused otherwise) and re-keys this restricted registry to the new name;
	// the running VZ instance never notices — open fds follow the moved inodes. The disks
	// the run attached directly (the original's unsafe storage raws) move into the saved VM's
	// folder, and the original keeps them as references (C5). The promoted VM gets FRESH
	// identity like vm.copy (user decision): new MAC now, new machine ids effective next
	// boot, created = now, runtime restarts (the in-flight session re-adds at teardown
	// through the re-pointed config).
	func promoteRestrictedVM(to newName: String) throws -> VirtualMachine {
		guard let oldName = restrictedName, let library = promotionLibrary else {
			throw MachmanError(
				code: .invalidState, message: "Only a safe run can be saved as a new VM")
		}
		guard let vm = vms[oldName], let runtime = vm.runtime else {
			throw MachmanError(code: .invalidState, message: "The safe run already ended")
		}
		try NameRule.vmName.validate(newName)
		let runRoot = machmanVMDir
		let shadow = runRoot + "/" + oldName
		let destination = library + "/" + newName
		let originalDir = library + "/" + oldName
		// Read before anything moves. Unreadable, nothing is handed over: the run's direct
		// disks stay references into the original's folder, which the cross-VM guards keep.
		let original = BootGuard.peekConfig(name: oldName, library: library)
		// One atomic same-volume rename, never a copy (E15). The guest writes these images
		// through open descriptors, which follow a rename but not a copy: a cross-volume
		// move copied a torn image while the guest kept writing the unlinked originals, and
		// froze this vmhost's main actor for the whole copy. safe/ is a sibling of VMs/, so
		// only a symlinked or mounted VMs folder is ever on another volume. The rename is
		// the first mutation: a refusal leaves the run untouched.
		try moveExclusively(shadow, to: destination, saving: newName, folder: true)
		let savedFiles = Set(
			(try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? [])
		let moves = original.map {
			DirectDiskMove.plan(
				run: vm.config, attached: runtime.attachedDiskFiles, original: $0,
				originalDir: originalDir, savedFiles: savedFiles)
		} ?? []
		// The hand-over (C5), in an order that keeps the guest's data reachable from a
		// config at every point: the saved VM's config (its new storage entries name files
		// not there yet), then the disks, then the original's config. Any failure rolls
		// back every rename and the run goes on untouched. Accepted crash windows: dying
		// before the disks moved leaves the saved VM missing them (still the original's);
		// dying after leaves the original missing them (now the saved VM's). Either way no
		// file is lost, and one VM still lists each disk.
		let snapshot = PromotionSnapshot(vm.config)
		let shadowConfig = try? Data(contentsOf: URL(fileURLWithPath: destination + "/config"))
		var moved: [DirectDiskMove] = []
		do {
			// From here the VM lives in the library: every config path resolves through the
			// re-pointed global + the new name.
			machmanVMDir = library
			vm.config.name = newName
			vm.config.created = Date()
			vm.config.totalRuntimeSeconds = 0
			// The directory just moved out of the run root — re-point the owned kernel and
			// iso references or the promoted VM boots from a directory the sweep deletes.
			vm.config.rewriteOwnedPaths(fromDir: shadow, toDir: destination, .moved)
			vm.config.adoptMovedDisks(moves, from: originalDir)
			// Fresh machine, fresh ssh instance identity, the vm.copy rule: the alias still
			// belongs to the source VM, the lease follows the source's MAC, and the reverse
			// grant is labeled with the source's marker.
			vm.config.dropAlias()
			vm.config.ssh?.resetInstanceIdentity()
			// Decision 12, as for a copy: the guest's reports still carry the original's
			// marker, which the report gate ignores (PR4), so the saved VM forgets the last
			// setup run and serves the installer at its next boot. Its traveled keypair stays
			// for the running guest; the next served start re-mints it (marker drift).
			vm.config.setup?.resetForFreshIdentity()
			// Saving as a new VM takes a name: yield to every VM in the library.
			vm.config.assignDefaultAliasIfTaken()
			try vm.config.regenerateMACAddress()   // the saved VM's one save, at the new path
			for move in moves {
				try moveExclusively(
					originalDir + "/" + move.sourceFile, to: destination + "/" + move.targetFile,
					saving: newName, folder: false)
				moved.append(move)
			}
			if original != nil, !moves.isEmpty {
				// Rewritten at the original's own folder: nothing hosts it now (this run IS
				// that VM), so this process is its config's single writer (Q39).
				try VMConfig.rewrite(atDir: originalDir) {
					$0.referenceMovedDisks(moves, in: destination)
				}
			}
		} catch {
			var stranded: [DirectDiskMove] = []
			for move in moved.reversed() {
				let back = originalDir + "/" + move.sourceFile
				if !restore(destination + "/" + move.targetFile, to: back) {
					stranded.append(move)
				}
			}
			snapshot.restore(vm.config)
			// A disk that could not go back keeps the saved folder in the library, where its
			// config lists it: the run root is deleted when the run ends. So does a folder
			// whose own way back fails. Either way the saved VM stays a VM of its own: both
			// configs say where each disk is, so the guards keep the folder while the original
			// uses it, and it never boots as the original's machine.
			if stranded.isEmpty, restore(destination, to: shadow) {
				try? shadowConfig?.write(
					to: URL(fileURLWithPath: shadow + "/config"), options: .atomic)
			} else {
				DirectDiskMove.settleStranded(
					stranded, of: moves, originalDir: originalDir, savedDir: destination)
				Self.mintMachineIdentity(in: destination, boot: vm.config.boot)
				MachmanLogger.log(.passiveError,
					"Save as New VM failed half-way: \(newName) stays in the library "
						+ (stranded.isEmpty
							? "because its folder could not go back"
							: "with the disks that could not go back to \(oldName)"))
			}
			// Back to the run root only now: the configs rewritten above resolve their names
			// against the library they live in.
			machmanVMDir = runRoot
			throw error
		}
		restrictedName = newName
		vms[oldName] = nil
		vms[newName] = vm
		presenter.rekey(from: oldName, to: newName)
		Self.mintMachineIdentity(in: destination, boot: vm.config.boot)
		// With the pin reset this just drops the traveled known_hosts, which was keyed to
		// the source's alias; the next guest report re-pins under the new alias.
		SSHSetupInstaller.writeKnownHosts(for: vm.config)
		try? FileManager.default.removeItem(atPath: runRoot)   // now-empty run root + marker
		promotionLibrary = nil
		if let warning = DirectDiskMove.handOverWarning(moves, original: oldName) {
			events.emit(.log(vm: newName, level: .warning, message: warning))
		}
		onPromoted?(oldName, newName)
		return vm
	}

	// A saved VM's own machine, vm.copy's rule: its identifier is recreated at the next boot
	// and a macOS VM gets a fresh machine id. The running guest keeps the one it booted with.
	private static func mintMachineIdentity(in dir: String, boot: BootConfig) {
		try? FileManager.default.removeItem(atPath: dir + "/vm_identifier")
		if case .macOS = boot {
			try? VMConfig.mintMacMachineIdentifier(at: dir + "/mac_machine_id")
		}
	}

	// One exclusive rename for Save as New VM, or the save's error for it.
	private func moveExclusively(
		_ from: String, to: String, saving newName: String, folder: Bool
	) throws {
		switch renameExclusive(from, to) {
		case 0:
			return
		case EEXIST where folder, ENOTEMPTY where folder:
			throw MachmanError(
				code: .alreadyExists,
				message: "A VM named \u{201C}\(newName)\u{201D} already exists")
		case EXDEV:
			throw MachmanError(
				code: .invalidState,
				message: "Save as New VM needs the VM library on the same volume as its "
					+ "safe runs")
		case let code:
			let what = folder ? "" : " (\((from as NSString).lastPathComponent))"
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t save \(newName)\(what): \(String(cString: strerror(code)))")
		}
	}

	// A failed save's way back. Never fails silently: a file left behind is named.
	private func restore(_ path: String, to original: String) -> Bool {
		let code = renameExclusive(path, original)
		guard code != 0 else { return true }
		MachmanLogger.log(.passiveError,
			"Save as New VM rollback: \(path) stays put, not back at \(original): "
				+ String(cString: strerror(code)))
		return false
	}

	// Register a directory that appeared after the initial scan (vm.copy now, safe-save
	// later). reload(name:) can't do this — it only refreshes names it already knows.
	// `library`: VMConfig.load's.
	func adoptFromDisk(name: String, library: String = machmanVMDir) throws -> VirtualMachine {
		guard restrictedName == nil else {
			throw MachmanError(code: .invalidState, message: "This process can’t adopt VMs")
		}
		guard vms[name] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "A VM named \u{201C}\(name)\u{201D} already exists")
		}
		let config: VMConfig
		do {
			config = try VMConfig.load(name: name, library: library)
		} catch {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t read the new VM \u{201C}\(name)\u{201D}: "
					+ MachmanError.userMessage(for: error))
		}
		config.excludeDiskImagesFromBackup()
		let vm = VirtualMachine(config: config, events: events)
		vms[name] = vm
		events.emit(.listChanged)
		return vm
	}

	// Interrupted copies leave hidden staging dirs. Safe to sweep whenever a daemon starts:
	// this daemon has no copy in flight yet, vmhosts never copy, and the socket mutex rules
	// out a second daemon. Deliberately daemon-only.
	public func sweepCopyStaging() {
		guard restrictedName == nil else { return }
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: machmanVMDir)
		else { return }
		for entry in entries where entry.hasPrefix(VMCopier.stagingPrefix) {
			try? FileManager.default.removeItem(atPath: machmanVMDir + "/" + entry)
			MachmanLogger.log(.log, "removed interrupted copy staging \(entry)")
		}
	}

	// Re-read one VM's config from disk (after a vmhost exits, the daemon's in-memory copy is
	// stale — the vmhost owned the file while the VM ran). `library`: VMConfig.load's.
	func reload(name: String, library: String = machmanVMDir) {
		guard vms[name] != nil else { return }
		if installSessions[name]?.isInstalling == true {
			// A live install saves through the config it started with; a second object would
			// fork the VM's state. Unreachable today: installs are refused while hosted.
			MachmanLogger.log(.passiveWarning, "kept \(name)'s config: a macOS install owns it")
			return
		}
		// A session holds the config it was made for, so the fresh config gets a fresh one:
		// a kept session would whole-file-save the pre-run config at its next install,
		// reverting everything the run persisted (E4).
		installSessions[name] = nil
		guard let fresh = try? VMConfig.load(name: name, library: library) else {
			vms[name] = nil
			events.emit(.listChanged)
			return
		}
		vms[name] = VirtualMachine(config: fresh, events: events)
	}

	func create() throws -> VirtualMachine {
		guard restrictedName == nil else {
			throw MachmanError(code: .invalidState, message: "This process can’t create VMs")
		}
		// A name the map lacks can still be taken on disk: a folder the scan skipped keeps a
		// config the user may restore, and its disks (D19). The folder is made exclusively, so
		// a new VM never writes into one.
		var nbr = 1
		var name = "new-VM1"
		while try vms[name] != nil || !VMConfig.createNewVMDirectory(name: name) {
			nbr += 1
			name = "new-VM\(nbr)"
		}
		let vm = VirtualMachine(
			config: try VMConfig(
				name: name, memorySize: ByteSize.fromGB(1),
				cpuCount: VMConfig.computeMaxCPUCount()),
			events: events)
		vms[name] = vm
		events.emit(.listChanged)
		return vm
	}

	func delete(_ vm: VirtualMachine) throws {
		let name = vm.config.name
		guard vm.runtime == nil else {
			throw MachmanError(code: .invalidState, message: "Stop \(name) before deleting it")
		}
		guard !(installSessions[name]?.isInstalling ?? false) else {
			throw MachmanError(
				code: .invalidState, message: "Wait for the macOS install to finish first")
		}
		// Another VM's disk may live in this folder (C5).
		if let ref = foreignReference(to: vm.config.vmDirPath(), excluding: name) {
			throw foreignUseRefusal(ref, owner: name)
		}
		do {
			try VMConfig.deleteVMDirectory(name: name)
		} catch {
			// What is left decides (E16): a readable config keeps the VM listed, so the
			// client's error and the list agree and the user can retry; one the partial
			// delete took is gone, as the next scan would have it.
			reload(name: name)
			events.emit(.listChanged)
			throw error
		}
		presenter.dropWindow(name: name)
		vms[name] = nil
		installSessions[name] = nil
		events.emit(.listChanged)
	}

	// The one entry check for a VM name taken by rename or copy (promotion checks the
	// library on disk instead). Refused, never trimmed: the router keys on the name as sent.
	func checkNewVMName(_ name: String) throws {
		try NameRule.vmName.validate(name)
		guard vms[name] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "A VM named \u{201C}\(name)\u{201D} already exists")
		}
	}

	func rename(_ vm: VirtualMachine, to newName: String) throws {
		let oldName = vm.config.name
		guard oldName != newName else { return }
		try checkNewVMName(newName)
		guard vm.runtime == nil else {
			throw MachmanError(code: .invalidState, message: "Stop \(oldName) before renaming it")
		}
		// The installer writes into the folder the rename would move (E15b).
		guard !(installSessions[oldName]?.isInstalling ?? false) else {
			throw MachmanError(
				code: .invalidState, message: "Wait for the macOS install to finish first")
		}
		// …and so would another VM whose disk lives in it (C5).
		if let ref = foreignReference(to: vm.config.vmDirPath(), excluding: oldName) {
			throw foreignUseRefusal(ref, owner: oldName)
		}
		try vm.config.rename(to: newName)
		vms[oldName] = nil
		vms[newName] = vm
		if let session = installSessions.removeValue(forKey: oldName) {
			installSessions[newName] = session
		}
		events.emit(.listChanged)
	}

	// MARK: - macOS install sessions

	func installSession(for vm: VirtualMachine) -> InstallSession {
		if let existing = installSessions[vm.config.name] {
			return existing
		}
		let session = InstallSession(
			config: vm.config, events: events,
			// The registry's CURRENT VM by the session config's current name (a rename
			// re-keys sessions): a captured VirtualMachine goes stale at the next reload.
			isVMRunning: { [weak self, config = vm.config] in
				self?.vms[config.name]?.state.isRunning ?? false
			},
			run: installRunner)
		installSessions[vm.config.name] = session
		return session
	}

	func isInstalling(_ vm: VirtualMachine) -> Bool {
		installSessions[vm.config.name]?.isInstalling ?? false
	}
}
