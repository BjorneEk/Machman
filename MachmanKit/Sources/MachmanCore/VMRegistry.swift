//
//  VMRegistry.swift
//  Machman
//
//  The engine facade: the single authority over which VMs exist and which are running. Owns the
//  event bus and the window presenter; enforces cross-VM invariants (unique names, no
//  delete/rename while running). This is what LocalMachman wraps for the API.
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
	let events = EventBus()
	let presenter = WindowPresenter()
	private(set) var vms: [String: VirtualMachine] = [:]
	// Sessions live here (not in a view) so a running install keeps its phase and progress
	// when the user navigates away, and a second install of the same VM can't start.
	private var installSessions: [String: InstallSession] = [:]
	// Non-nil in a vmhost process: this registry manages exactly that one VM.
	// var: safeSave promotion re-keys the vmhost to the saved VM's name. Internal read —
	// the bootstrap's lifecycle watcher and quit delegate follow it instead of a stale
	// captured launch name.
	private(set) var restrictedName: String?
	// Safe-run vmhosts only: where vm.safeSave promotes the shadow to. nil everywhere else,
	// which is what makes safeSave refusable outside a daemon-spawned safe run; cleared
	// after use so a run promotes at most once.
	private var promotionLibrary: String?

	public convenience init() {
		self.init(only: nil)
	}

	// `only`: restrict the registry to a single VM (the vmhost case) — the scan ignores every
	// other directory and create() is refused.
	public init(only restrictedName: String?, promotionLibrary: String? = nil) {
		self.restrictedName = restrictedName
		self.promotionLibrary = promotionLibrary
		presenter.stopHandler = { [weak self] name, mode in
			guard let self = self, let vm = self.vms[name] else { return }
			Task {
				do {
					try await self.stop(vm, mode: mode)
				} catch {
					vm.log(error: "Failed to stop VM: \(name): \(error)")
				}
			}
		}
		presenter.isRunning = { [weak self] name in
			self?.vms[name]?.state.isRunning ?? false
		}
		presenter.onWindowChanged = { [weak self] in
			self?.events.emit(.listChanged)
		}
		presenter.onCaptureFailed = { [weak self] failure in
			switch failure {
			case .windowNotFound(let id):
				self?.events.emit(.log(
					vm: nil, level: .warning,
					message: "VM window \(id) was not found on screen — preview is blank."))
				return
			case .captureReturnedNothing:
				self?.events.emit(.log(
					vm: nil, level: .warning,
					message: "ScreenCaptureKit returned no image — preview is blank."))
				return
			case .noPermission:
				// Vmhosts launch as standalone apps, so TCC attributes capture requests to
				// MachmanVMHost itself — that is the row in System Settings (dev builds show
				// "MachmanVMHost (Dev)"). macOS caches the answer per process, so a fresh
				// grant is invisible until this VM's host process is relaunched.
				self?.events.emit(.log(
					vm: nil, level: .warning,
					message: "Screen Recording is not granted — VM previews will be blank. "
						+ "Enable it for MachmanVMHost in System Settings > Privacy & Security > "
						+ "Screen Recording, then stop and start this VM: a running process "
						+ "cannot see a grant it was launched without."))
			}
		}
		scan()
	}

	private func scan() {
		// First run against a fresh library: the directory simply doesn't exist yet.
		ensureDirectory(machmanVMDir)
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
				message: "(\(vm.config.name)) cannot start while macOS is installing")
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
					vm: vm.config.name, level: .warning,
					message: "\(vm.config.name) has no display device — started headless"))
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
				message: "\(vm.config.name) has no display device — add a graphics "
					+ "device and restart to use a window")
		}
		presenter.openWindow(name: vm.config.name, vz: vz)
	}

	func closeWindow(_ vm: VirtualMachine) {
		presenter.dropWindow(name: vm.config.name)
	}

	func isWindowOpen(_ vm: VirtualMachine) -> Bool {
		presenter.window(for: vm.config.name) != nil
	}

	func captureImage(name: String) async -> NSImage {
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
		return vm.config.configFilePath(file: "serial-\(kind.rawValue)\(index).log")
	}

	func retuneSerialLogging(
		vm: VirtualMachine, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) {
		vm.runtime?.retuneSerialLogging(kind: kind, index: index, config: config)
	}

	// MARK: - Create / delete / rename

	// "<base>", "<base> 2", "<base> 3", … probed against the in-memory map.
	func uniqueName(base: String) -> String {
		guard vms[base] != nil else { return base }
		var n = 2
		while vms["\(base) \(n)"] != nil { n += 1 }
		return "\(base) \(n)"
	}

	// vm.safeSave's engine half — vmhost-side ONLY (single-writer: the vmhost moves files it
	// owns). Renames the shadow dir into the library atomically (same volume by
	// construction) and re-keys this restricted registry to the new name; the running VZ
	// instance never notices — open fds follow the moved inodes. The promoted VM gets FRESH
	// identity like vm.copy (user decision): new MAC now, new machine ids effective next
	// boot, created = now, runtime restarts (the in-flight session re-adds at teardown
	// through the re-pointed config).
	func promoteRestrictedVM(to newName: String) throws -> VirtualMachine {
		guard let oldName = restrictedName, let library = promotionLibrary else {
			throw MachmanError(
				code: .invalidState, message: "only a safe-run vmhost can save as a new VM")
		}
		guard let vm = vms[oldName], vm.runtime != nil else {
			throw MachmanError(code: .invalidState, message: "the safe run already ended")
		}
		guard !newName.isEmpty, !newName.contains("/") else {
			throw MachmanError(
				code: .invalidArgument, message: "invalid VM name '\(newName)'")
		}
		let destination = library + "/" + newName
		guard !FileManager.default.fileExists(atPath: destination) else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(newName)' already exists")
		}
		let runRoot = machmanVMDir
		do {
			try FileManager.default.moveItem(
				atPath: runRoot + "/" + oldName, toPath: destination)
		} catch {
			if FileManager.default.fileExists(atPath: destination) {
				// The name appeared while we checked; the rename lost the race.
				throw MachmanError(
					code: .alreadyExists, message: "a VM named '\(newName)' already exists")
			}
			throw MachmanError(
				code: .ioFailure,
				message: "saving \(newName): \(error.localizedDescription)")
		}
		// From here the VM lives in the library: every config path resolves through the
		// re-pointed global + the new name.
		machmanVMDir = library
		restrictedName = newName
		vms[oldName] = nil
		vms[newName] = vm
		vm.config.name = newName
		presenter.rekey(from: oldName, to: newName)
		vm.config.created = Date()
		vm.config.totalRuntimeSeconds = 0
		try? FileManager.default.removeItem(atPath: destination + "/vm_identifier")
		if case .macOS = vm.config.boot {
			try? VMConfig.mintMacMachineIdentifier(at: destination + "/mac_machine_id")
		}
		try vm.config.regenerateMACAddress()   // the one save, at the new path
		try? FileManager.default.removeItem(atPath: runRoot)   // now-empty run root + marker
		promotionLibrary = nil
		return vm
	}

	// Register a directory that appeared after the initial scan (vm.copy now, safe-save
	// later). reload(name:) can't do this — it only refreshes names it already knows.
	func adoptFromDisk(name: String) throws -> VirtualMachine {
		guard restrictedName == nil else {
			throw MachmanError(code: .invalidState, message: "a vmhost cannot adopt VMs")
		}
		guard vms[name] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(name)' already exists")
		}
		let config: VMConfig
		do {
			config = try VMConfig.load(name: name)
		} catch {
			throw MachmanError(
				code: .ioFailure, message: "cannot read the new VM '\(name)': \(error)")
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
	// stale — the vmhost owned the file while the VM ran).
	func reload(name: String) {
		guard vms[name] != nil else { return }
		guard let fresh = try? VMConfig.load(name: name) else {
			vms[name] = nil
			events.emit(.listChanged)
			return
		}
		vms[name] = VirtualMachine(config: fresh, events: events)
	}

	func create() throws -> VirtualMachine {
		guard restrictedName == nil else {
			throw MachmanError(code: .invalidState, message: "a vmhost cannot create VMs")
		}
		var nbr = 1
		while vms["new-VM\(nbr)"] != nil {
			nbr += 1
		}
		let name = "new-VM\(nbr)"
		try VMConfig.createNewVMDirectory(name: name)
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
			throw MachmanError(code: .invalidState, message: "stop \(name) before deleting it")
		}
		guard !(installSessions[name]?.isInstalling ?? false) else {
			throw MachmanError(
				code: .invalidState, message: "wait for the macOS install to finish first")
		}
		presenter.dropWindow(name: name)
		vms[name] = nil
		installSessions[name] = nil
		try VMConfig.deleteVMDirectory(name: name)
		events.emit(.listChanged)
	}

	func rename(_ vm: VirtualMachine, to newName: String) throws {
		let oldName = vm.config.name
		guard oldName != newName else { return }
		guard vms[newName] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(newName)' already exists")
		}
		guard vm.runtime == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(oldName) before renaming it")
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
			isVMRunning: { [weak vm] in vm?.state.isRunning ?? false })
		installSessions[vm.config.name] = session
		return session
	}

	func isInstalling(_ vm: VirtualMachine) -> Bool {
		installSessions[vm.config.name]?.isInstalling ?? false
	}
}
