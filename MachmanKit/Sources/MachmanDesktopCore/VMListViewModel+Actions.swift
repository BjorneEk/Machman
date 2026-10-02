//
//  VMListViewModel+Actions.swift
//  MachmanDesktopCore
//
//  What the user asks of the daemon: every request a view, a menu or the Dock sends, with
//  the question that confirms it first when it destroys something (request →
//  confirmationDialog → perform), sectioned by what it acts on. Every request runs in one
//  shape, perform (Q1): how it goes out, and what it says when it succeeds or is refused,
//  is decided there once.
//

import Foundation
import MachmanUI
import MachmanAPI

// What an action toasts when it went through.
struct ActionToast {
	let symbol: String
	let message: String
}

extension VMListViewModel {
	// MARK: - The runner (Q1)

	// The one shape a request to the daemon runs in. The call goes out off the click, on the
	// api alone: a view model that went with its connection sends nothing, and a call in
	// flight doesn't keep it alive. A success runs `then` with the reply, then shows
	// `toast`. A refusal runs `failed` first (undoing what the click set up), then `recover`
	// may answer a MachmanError that isn't a failure (true: nothing more is said); anything
	// else goes to the field that asked (`refused`) or to an alert titled "<action> failed".
	// Every step runs only while the view model is still here.
	func perform<Value>(
		_ action: String, toast: ActionToast? = nil,
		refused: (@MainActor (String) -> Void)? = nil,
		failed: (@MainActor (VMListViewModel) -> Void)? = nil,
		recover: (@MainActor (VMListViewModel, MachmanError) -> Bool)? = nil,
		_ call: @escaping @MainActor (any MachmanControlling) async throws -> Value,
		then: (@MainActor (VMListViewModel, Value) -> Void)? = nil
	) {
		Task { [weak self] in
			guard let api = self?.api else { return }
			do {
				let value = try await call(api)
				guard let self else { return }
				then?(self, value)
				if let toast { self.pushToast(symbol: toast.symbol, message: toast.message) }
			} catch {
				guard let self else { return }
				failed?(self)
				if let error = error as? MachmanError, recover?(self, error) == true { return }
				self.refuse(error, while: action, to: refused)
			}
		}
	}

	// MARK: - VM

	public func toggleRun(_ vm: VMInfo) {
		if vm.state.isRunning {
			stopVM(vm.name)
		} else {
			startPolicyDriven(vm)
		}
	}

	public func isStartPending(_ name: String) -> Bool {
		pendingStarts.contains(name)
	}

	// The low-level start with exact options. Affordances never call it: they go through
	// startPolicyDriven (VMListViewModel+Start.swift), which applies the VM's start policy.
	// Only the MAC-conflict retry, which repeats a refused start with force, needs it.
	public func startVM(
		_ name: String, headless: Bool = false, force: Bool = false, safe: Bool = false
	) {
		guard !pendingStarts.contains(name) else { return }
		pendingStarts.insert(name)
		Task { [weak self] in
			defer { self?.pendingStarts.remove(name) }
			do {
				try await self?.api.start(
					vm: name,
					options: StartOptions(openWindow: !headless, force: force, safe: safe))
				// A fresh list before the flag drops, so the affordances flip straight
				// from pending to the running controls, never through a stale Start.
				await self?.reload()
			} catch let error as MachmanError where error.code == .macConflict {
				// Not a dead end: the same start succeeds with force, so offer it.
				self?.pendingForceStart = PendingForceStart(
					name: name, headless: headless, safe: safe, message: error.message)
			} catch {
				self?.present(error, while: "Starting \u{201C}\(name)\u{201D}")
			}
		}
	}

	public func openWindow(_ name: String) {
		perform("Opening the \u{201C}\(name)\u{201D} window") { try await $0.openWindow(vm: name) }
	}

	public func closeWindow(_ name: String) {
		perform("Closing the \u{201C}\(name)\u{201D} window") { try await $0.closeWindow(vm: name) }
	}

	public func stopVM(_ name: String, mode: StopMode = .force) {
		let action = mode == .soft ? "Shutting down" : "Force stopping"
		perform("\(action) \u{201C}\(name)\u{201D}") { try await $0.stop(vm: name, mode: mode) }
	}

	public func createVM(template: VMTemplate? = nil) async -> String? {
		do {
			let vm = try await api.createVM(template: template)
			await reload()
			return vm.name
		} catch {
			present(error, while: "Creating a VM")
			return nil
		}
	}

	// The New VM picker's macOS template (H21, decision 15): it opens straight into the
	// Install macOS flow. Nothing is created until a source is picked; then the VM is made
	// from the mac template, selected, and its install starts — no EFI VM left waiting for
	// Bootloader ▸ macOS…, and a cancelled pick leaves no stray VM.
	public func createMacVM(source: InstallSource) async {
		guard let name = await createVM(template: .mac) else { return }
		select(name: name)
		startInstall(name, source: source)
	}

	// Request → confirmationDialog → perform (all deletes follow this shape).
	public func deleteVM(_ vm: VMInfo) {
		pendingVMDelete = vm
	}

	// Delete VM…'s question (X7: one sentence; the title names the VM, so the message
	// doesn't). The window's confirmationDialog shows it; a test can pin it here.
	public static func deleteVMTitle(_ name: String) -> String {
		"Delete \u{201C}\(name)\u{201D}?"
	}

	public static let deleteVMMessage = "The VM and the files it owns are deleted permanently."

	public func performDeleteVM(_ vm: VMInfo) {
		perform("Deleting \u{201C}\(vm.name)\u{201D}") {
			try await $0.deleteVM(named: vm.name)
		} then: { model, _ in
			// The picker can delete a VM that isn't the shown one — keep the selection
			// unless it was the one deleted.
			if model.selectedName == vm.name {
				model.select(name: nil)
			}
		}
	}

	public func rename(from oldName: String, to newName: String) async -> Bool {
		await rename(from: oldName, to: newName, refused: nil)
	}

	// `refused` takes a refusal to the field that asked, instead of an alert (PR8).
	func rename(
		from oldName: String, to newName: String, refused: (@MainActor (String) -> Void)?
	) async -> Bool {
		do {
			try await api.renameVM(named: oldName, to: newName)
			// Migrate open terminal tabs BEFORE reload()'s reconcile sees the new name (else the
			// old-keyed session would look like a vanished VM and its terminals get closed).
			migrateClientState(from: oldName, to: newName)
			await reload()
			select(name: newName)
			reopenTornWindows(from: oldName, to: newName)
			return true
		} catch {
			refuse(error, while: "Renaming \u{201C}\(oldName)\u{201D}", to: refused)
			return false
		}
	}

	// A VM's client-side state follows it to a new name: live terminals and ssh sessions,
	// the canvas layout and the last preview frame.
	private func migrateClientState(from old: String, to new: String) {
		terminals.renameVM(from: old, to: new)
		canvases.renameVM(from: old, to: new)
		previews.renameVM(from: old, to: new)
	}

	// Torn windows cannot re-key their birth payload — swap them (T3): each old-named
	// window is ordered to reopen as the new name, adopting the live controller the
	// migration re-keyed. Posted AFTER the reload: a rename's reconcile just marked these
	// payloads close (old name gone from the fresh list), and this overwrite lands in the
	// same main-actor job, before any window can act on it.
	private func reopenTornWindows(from old: String, to new: String) {
		let registry = tornTabs
		for torn in registry.open where torn.vm == old {
			registry.orders[torn] = .reopen(as: TornTab(vm: new, tab: torn.tab))
		}
	}

	// The one rename flow (tree rename-in-place + the VM inspector's name field): trimmed,
	// checked against the VM-name rule and the list before the daemon sees it, migrating
	// terminal/canvas/preview/profile state on success. `reverted` runs when the typed name
	// is not applied (blank, unchanged, refused here or by the daemon), so a field can drop
	// it instead of showing a name the VM doesn't have. `refused` (last, so a trailing
	// closure still means `reverted`) takes a refusal to the field instead of an alert.
	public func requestRename(
		_ vm: VMInfo, to typed: String, profiles: TerminalProfileStore,
		reverted: @escaping @MainActor () -> Void = {},
		refused: (@MainActor (String) -> Void)? = nil
	) {
		let old = vm.name
		let newName = NameRule.vmName.trimmed(typed)
		guard !newName.isEmpty, newName != old else {
			reverted()
			return
		}
		if let problem = newVMNameProblem(newName) {
			refuse(problem, while: "Renaming \u{201C}\(old)\u{201D}", to: refused)
			reverted()
			return
		}
		Task { [weak self] in
			guard let self = self else { return }
			if await self.rename(from: old, to: newName, refused: refused) {
				profiles.renameVM(from: old, to: newName)
				self.log(message: "Renamed \(old) to \(newName)")
				self.pushToast(
					symbol: MachmanSymbols.rename,
					message: ToastWording.renamed(to: newName))
			} else {
				reverted()
			}
		}
	}

	public func setHardware(
		_ name: String, cpuCount: Int? = nil, memoryBytes: UInt64? = nil, nested: Bool? = nil
	) {
		perform("Updating hardware for \u{201C}\(name)\u{201D}") {
			try await $0.setHardware(
				vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
				nestedVirtualization: nested)
		}
	}

	public func requestCopy(_ vm: VMInfo) {
		// The sheet's space hint reads capabilities.freeDiskBytes, fetched once at connect —
		// refresh so the figure isn't sessions old.
		Task { [weak self] in
			await self?.store.refreshCapabilities()
		}
		copyRequest = vm
	}

	public func copyVM(
		_ name: String, newName: String, diskIDs: [String], mountIDs: [String]? = nil
	) {
		guard !copyInFlight else { return }
		copyInFlight = true
		copyRequest = nil   // the sheet closes now; the corner card tracks the copy
		Task { [weak self] in
			do {
				let copy = try await self?.api.copyVM(
					vm: name, newName: newName, diskIDs: diskIDs, mountIDs: mountIDs,
					regenerateMAC: true)
				self?.copyInFlight = false
				await self?.reload()
				if let copy { self?.select(name: copy.name) }
			} catch {
				self?.copyInFlight = false
				self?.present(error, while: "Duplicating \u{201C}\(name)\u{201D}")
			}
		}
	}

	// Duplicate…'s choices beyond the name: which mounts the copy keeps (C11).
	// The mounts Duplicate… sends: nil while every mount is ticked — every mount travels,
	// the request an older daemon knows too — else the ticked ones in the VM's order.
	public nonisolated static func copyMountIDs(
		for vm: VMInfo, included: Set<String>
	) -> [String]? {
		let all = vm.mounts.map(\.id)
		guard !all.allSatisfy(included.contains) else { return nil }
		return all.filter(included.contains)
	}

	public func requestSafeSave(_ vm: VMInfo) {
		safeSaveRequest = vm
	}

	public func safeSave(_ name: String, to newName: String) {
		guard !safeSaveInFlight else { return }
		safeSaveInFlight = true
		Task { [weak self] in
			do {
				let saved = try await self?.api.safeSave(vm: name, to: newName)
				// The run continues as the new VM (the daemon re-keys the live host and keeps
				// the original, stopped), so its terminals, sessions, layout, torn windows and
				// last frame go with it — as a rename's do. The original starts fresh and
				// connects anew when it is started (T17).
				if let saved { self?.migrateClientState(from: name, to: saved.name) }
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // item binding dismisses the sheet
				await self?.reload()
				if let saved {
					self?.select(name: saved.name)
					self?.reopenTornWindows(from: name, to: saved.name)
				}
			} catch {
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // dismiss first; alert isn't sheet-blocked
				self?.present(error, while: "Saving \u{201C}\(name)\u{201D} as a new VM")
			}
		}
	}

	public func setStartPolicy(_ name: String, policy: StartPolicy) {
		perform("Updating the default start for \u{201C}\(name)\u{201D}") {
			try await $0.setStartPolicy(vm: name, policy: policy)
		}
	}

	public func regenerateMAC(_ name: String) {
		perform(
			"Regenerating the MAC address",
			toast: ActionToast(
				symbol: MachmanSymbols.regenerate, message: "MAC address regenerated")
		) { try await $0.regenerateMAC(vm: name) }
	}

	// System-prompted host install; capabilities refresh afterwards so the availability
	// row flips without a reconnect.
	public func installRosetta() {
		Task { [weak self] in
			do {
				try await self?.api.installRosetta()
				await self?.store.refreshCapabilities()
			} catch {
				self?.present(error, while: "Installing Rosetta")
			}
		}
	}

	// MARK: - Disks

	// Owned disks confirm (the backing file dies with the entry); references detach silently.
	public func requestRemoveDisk(_ name: String, disk: DiskInfo) {
		if disk.owned == true {
			pendingDiskDelete = PendingDiskDelete(vm: name, disk: disk)
		} else {
			removeDisk(name, diskID: disk.id)
		}
	}

	// A batch copies one file after another: one disk-heavy copy at a time, and a daemon from
	// before wave 2 picked each name when its copy started. A failed file gets its own
	// alert and the rest carry on.
	public func importDisks(_ name: String, paths: [String]) {
		Task { [weak self] in
			for path in paths {
				guard let api = self?.api else { return }
				do {
					_ = try await api.importDisk(vm: name, path: path)
				} catch {
					let file = (path as NSString).lastPathComponent
					let action = "Importing \u{201C}\(file)\u{201D} into \u{201C}\(name)\u{201D}"
					self?.present(error, while: action)
				}
			}
		}
	}

	public func importDisk(_ name: String, path: String) {
		perform("Importing a disk into \u{201C}\(name)\u{201D}") {
			try await $0.importDisk(vm: name, path: path)
		}
	}

	public func promoteDisk(_ name: String, diskID: String) {
		perform("Promoting a disk on \u{201C}\(name)\u{201D}") {
			try await $0.promoteDisk(vm: name, diskID: diskID)
		}
	}

	// The disk id derives from the name, so a successful rename repoints a selection that
	// was on the old id (the inspector would otherwise go blank). `refused` takes a refusal
	// to the field instead of an alert.
	public func renameDisk(
		_ name: String, diskID: String, newName: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		perform(
			"Renaming a disk",
			toast: ActionToast(
				symbol: MachmanSymbols.rename, message: ToastWording.renamed(to: newName)),
			refused: refused
		) {
			try await $0.renameDisk(vm: name, diskID: diskID, newName: newName)
		} then: { model, updated in
			if model.treeSelection == [.disk(diskID)],
				let newID = updated.disks.first(where: { $0.name == newName })?.id {
				model.treeSelection = [.disk(newID)]
			}
		}
	}

	public func resizeDisk(_ name: String, diskID: String, sizeBytes: UInt64) {
		perform(
			"Growing a disk",
			toast: ActionToast(
				symbol: MachmanSymbols.diskSize,
				message: "Disk grown to \(ByteSize.display(sizeBytes))")
		) { try await $0.resizeDisk(vm: name, diskID: diskID, sizeBytes: sizeBytes) }
	}

	public func setDiskSafety(_ name: String, diskID: String, safe: Bool) {
		perform("Updating disk safety") {
			try await $0.setSafety(vm: name, disks: [diskID: safe], mounts: nil)
		}
	}

	public func addDisk(_ name: String, _ disk: NewDisk) {
		perform(
			"Adding a disk",
			toast: ActionToast(symbol: MachmanSymbols.diskStorage, message: "Added disk")
		) { try await $0.addDisk(vm: name, disk) }
	}

	// References for a batch, one toast for all of them.
	public func addDisks(_ name: String, _ disks: [NewDisk]) {
		Task { [weak self] in
			var added = 0
			for disk in disks {
				guard let api = self?.api else { return }
				do {
					try await api.addDisk(vm: name, disk)
					added += 1
				} catch {
					let file = disk.path.map { ($0 as NSString).lastPathComponent }
					let action = file.map { "Adding \u{201C}\($0)\u{201D}" } ?? "Adding a disk"
					self?.present(error, while: action)
				}
			}
			guard added > 0 else { return }
			self?.pushToast(
				symbol: MachmanSymbols.diskStorage,
				message: added == 1 ? "Added disk" : "Added \(added) disks")
		}
	}

	public func removeDisk(_ name: String, diskID: String) {
		perform(
			"Removing a disk",
			toast: ActionToast(symbol: MachmanSymbols.diskStorage, message: "Removed disk")
		) { try await $0.removeDisk(vm: name, diskID: diskID) }
	}

	// MARK: - Mounts

	public func addMount(_ name: String, path: String, tag: String, kind: String? = nil) {
		// Every drop, paste and picker passes the folder's name: one the mount-tag rule
		// refuses (.config, a:b) mounts under a cleaned tag the user can rename.
		let rule = NameRule.mountTag
		let tag = rule.problem(rule.trimmed(tag)) == nil
			? tag : rule.suggestion(from: tag, fallback: "share")
		perform(
			"Adding a mount",
			toast: ActionToast(
				symbol: MachmanSymbols.mount, message: "Added mount \u{201C}\(tag)\u{201D}")
		) { try await $0.addMount(vm: name, path: path, tag: tag, kind: kind) }
	}

	public func removeMount(_ name: String, mountID: String) {
		perform(
			"Removing a mount",
			toast: ActionToast(symbol: MachmanSymbols.mount, message: "Removed mount")
		) { try await $0.removeMount(vm: name, mountID: mountID) }
	}

	public func setMountTag(
		_ name: String, mountID: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		perform(
			"Changing a mount tag",
			toast: ActionToast(
				symbol: MachmanSymbols.rename, message: ToastWording.renamed(to: tag)),
			refused: refused
		) { try await $0.setMountTag(vm: name, mountID: mountID, tag: tag) }
	}

	public func setMountKind(_ name: String, mountID: String, kind: String) {
		perform("Changing a mount’s kind") {
			try await $0.setMountKind(vm: name, mountID: mountID, kind: kind)
		}
	}

	public func setMountSafety(_ name: String, mountID: String, safe: Bool) {
		perform("Updating mount safety") {
			try await $0.setSafety(vm: name, disks: nil, mounts: [mountID: safe])
		}
	}

	// MARK: - Devices and serial ports

	public func addDevice(_ name: String, kind: DeviceKind) {
		perform(
			"Adding a device",
			toast: ActionToast(symbol: kind.displaySymbol, message: "Added \(kind.inlineLabel)")
		) { try await $0.addDevice(vm: name, kind: kind) }
	}

	public func removeDevice(_ name: String, kind: DeviceKind) {
		perform(
			"Removing a device",
			toast: ActionToast(symbol: kind.displaySymbol, message: "Removed \(kind.inlineLabel)")
		) { try await $0.removeDevice(vm: name, kind: kind) }
	}

	public func updateDevice(_ name: String, device: DeviceInfo) {
		perform("Updating a device") { try await $0.updateDevice(vm: name, device: device) }
	}

	public func addConsolePort(_ name: String) {
		perform(
			"Adding a console port",
			toast: ActionToast(symbol: MachmanSymbols.serialConsole, message: "Added console port")
		) { try await $0.addConsolePort(vm: name) }
	}

	public func removeConsolePort(_ name: String) {
		perform(
			"Removing a console port",
			toast: ActionToast(
				symbol: MachmanSymbols.serialConsole, message: "Removed console port")
		) { try await $0.removeConsolePort(vm: name) }
	}

	public func addUartPort(_ name: String) {
		perform(
			"Adding a UART port",
			toast: ActionToast(symbol: MachmanSymbols.serialUart, message: "Added UART port")
		) { try await $0.addUartPort(vm: name) }
	}

	public func removeUartPort(_ name: String) {
		perform(
			"Removing a UART port",
			toast: ActionToast(symbol: MachmanSymbols.serialUart, message: "Removed UART port")
		) { try await $0.removeUartPort(vm: name) }
	}

	public func setSerialLogging(
		_ name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) {
		perform("Updating serial logging") {
			try await $0.setSerialLogging(vm: name, kind: kind, index: index, config: config)
		}
	}

	// MARK: - Enabled flags

	// Batch enable/disable everything in the tree selection that carries the flag
	// (multi-select context menus + the multi-selection inspector), in one vm.setEnabled:
	// one config write, all or nothing (devices ride it since 1.0.12).
	public func setSelectionEnabled(_ enabled: Bool, vm: VMInfo) {
		// Only what still exists (T15): a stale selection must not send gone ids.
		let current = vms.first { $0.name == vm.name } ?? vm
		var disks: [String: Bool] = [:]
		var mounts: [String: Bool] = [:]
		var console: [String: Bool] = [:]
		var uart: [String: Bool] = [:]
		var devices: [String: Bool] = [:]
		let live = Self.liveNodes(
			treeSelection, in: current, openSessions: openSSHSessions(vm: current.name))
		for node in live {
			switch node {
			case .disk(let id):
				disks[id] = enabled
			case .mount(let id):
				mounts[id] = enabled
			case .serial(let ref):
				if ref.kind == .console {
					console[String(ref.index)] = enabled
				} else {
					uart[String(ref.index)] = enabled
				}
			case .device(let kind):
				// .unknown can't name the device it stands for; leave it out.
				if kind != .unknown, current.devices?.contains(where: { $0.kind == kind }) == true {
					devices[kind.rawValue] = enabled
				}
			default:
				break
			}
		}
		if !disks.isEmpty || !mounts.isEmpty || !console.isEmpty || !uart.isEmpty
			|| !devices.isEmpty {
			setEnabled(
				vm.name, disks: disks.isEmpty ? nil : disks,
				mounts: mounts.isEmpty ? nil : mounts,
				console: console.isEmpty ? nil : console,
				uart: uart.isEmpty ? nil : uart,
				devices: devices.isEmpty ? nil : devices)
		}
	}

	// Batch per-entity enabled flags; serial ports are keyed by their string index, devices
	// by their kind.
	public func setEnabled(
		_ name: String, disks: [String: Bool]? = nil, mounts: [String: Bool]? = nil,
		console: [String: Bool]? = nil, uart: [String: Bool]? = nil,
		devices: [String: Bool]? = nil
	) {
		perform("Updating enabled state") {
			try await $0.setEnabled(
				vm: name, disks: disks, mounts: mounts, console: console, uart: uart,
				devices: devices)
		}
	}

	// MARK: - Kernel

	public func requestDeleteKernel(_ name: String, path: String, fileName: String) {
		pendingKernelDelete = PendingKernelDelete(vm: name, path: path, fileName: fileName)
	}

	// The file's path changes with its tag — repoint a selection that was on the old path.
	// `refused` takes a refusal to the field instead of an alert.
	public func renameKernelTag(
		_ name: String, path: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		let fileName = (path as NSString).lastPathComponent
		perform("Renaming a kernel file", refused: refused) {
			try await $0.renameKernelFile(vm: name, path: path, tag: tag)
		} then: { model, updated in
			// Said only once the reply holds the file under its new tag.
			guard let file = updated.boot.ownedKernels?.first(where: {
				$0.tag == tag && $0.fileName == fileName
			}) else { return }
			let old: SidebarNode = file.role == .kernel ? .kernel(path) : .initramfs(path)
			if model.treeSelection == [old] {
				model.treeSelection = [file.role == .kernel
					? .kernel(file.path) : .initramfs(file.path)]
			}
			model.pushToast(
				symbol: MachmanSymbols.rename,
				message: ToastWording.renamed(to: tag))
		}
	}

	public func promoteKernel(_ name: String, role: KernelRole, sourcePath: String, tag: String) {
		perform("Promoting a kernel file") {
			try await $0.promoteKernelFile(vm: name, role: role, sourcePath: sourcePath, tag: tag)
		}
	}

	public func deleteKernel(_ name: String, path: String) {
		perform("Deleting a kernel file") { try await $0.deleteKernelFile(vm: name, path: path) }
	}

	public func setKernelBoot(_ name: String, enabled: Bool) async -> Bool {
		do {
			try await api.setKernelBoot(vm: name, enabled: enabled)
			return true
		} catch {
			present(error, while: "Switching boot mode")
			return false
		}
	}

	// Select/deselect an active kernel or initramfs file by rewiring the kernel-boot draft
	// (the settings survive as a draft even while the mode is EFI — never toggles the mode).
	public func setActiveKernelFile(_ vm: VMInfo, role: KernelRole, path: String?) {
		var settings = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		switch role {
		case .kernel: settings.kernelPath = path ?? ""
		case .initramfs: settings.initrdPath = path
		case .unknown: return   // decode fallback only — the tree never builds it
		}
		updateKernelSettings(vm.name, settings)
	}

	public func setKernelOverride(
		_ name: String, path: String, commandLine: String? = nil, overrideEnabled: Bool? = nil
	) {
		perform("Updating the kernel override") {
			try await $0.setKernelOverride(
				vm: name, path: path, commandLine: commandLine,
				overrideEnabled: overrideEnabled)
		}
	}

	public func updateKernelSettings(_ name: String, _ settings: KernelSettings) {
		perform("Saving kernel settings") { try await $0.updateKernelSettings(vm: name, settings) }
	}

	// MARK: - SSH and guest setup (1.0.5)

	// A failure is titled by what the toggle did: added or removed the alias.
	public func setSSHIntegration(_ name: String, enabled: Bool) {
		let alias = vms.first { $0.name == name }.map(SSHCommand.hostKeyAlias(for:))
			?? SSHAliasRule.defaultAlias(for: name)
		let action = enabled
			? "Adding \u{201C}\(alias)\u{201D} to your SSH config"
			: "Removing \u{201C}\(alias)\u{201D} from your SSH config"
		perform(action) {
			try await $0.setSSH(
				vm: name, integrationEnabled: enabled, reverseApproved: nil, alias: nil)
		}
	}

	// An empty alias resets the VM to its default "<vm>.machman" name.
	public func setSSHAlias(_ name: String, alias: String) {
		perform("Renaming the SSH alias") {
			try await $0.setSSH(
				vm: name, integrationEnabled: nil, reverseApproved: nil, alias: alias)
		}
	}

	// Deny answers a pending request; Revoke takes back an approved key.
	public func setSSHReverseApproved(_ name: String, approved: Bool) {
		let wasPending = vms.first { $0.name == name }?.ssh?.reverseState == .pending
		let verb = approved ? "Approved" : wasPending ? "Denied" : "Revoked"
		perform(
			"Updating guest access",
			toast: ActionToast(
				symbol: MachmanSymbols.deviceSSHSetup,
				message: "\(verb) \(name)’s access to this Mac")
		) {
			try await $0.setSSH(
				vm: name, integrationEnabled: nil, reverseApproved: approved, alias: nil)
		}
	}

	// Re-run Address Discovery and Check Connection: a spinner toast, then what it found —
	// even an unchanged address (F4).
	public func refreshSSH(_ name: String) {
		beginRediscovery(name)
		perform(
			"Looking for the address of \u{201C}\(name)\u{201D}",
			failed: { $0.endRediscovery(name) }
		) { try await $0.refreshSSH(vm: name) }
	}

	public func resetSSH(_ name: String) {
		perform(
			"Resetting SSH state",
			toast: ActionToast(
				symbol: MachmanSymbols.deviceSSHSetup, message: "SSH state reset for \(name)")
		) { try await $0.resetSSH(vm: name) }
	}

	public func resetSetup(_ name: String) {
		perform(
			"Resetting guest setup state",
			toast: ActionToast(
				symbol: MachmanSymbols.deviceGuestSetup,
				message: "Guest setup state reset for \(name)")
		) { try await $0.resetSetup(vm: name) }
	}

	// The Allow-reinstall toggle made real: serving on demand, clean share otherwise.
	public func setSetupServed(_ name: String, serve: Bool) {
		perform("Changing the reinstall setting") {
			try await $0.setSetupServed(vm: name, serve: serve)
		}
	}

	// MARK: - macOS install

	public func startInstall(_ name: String, source: InstallSource) {
		perform("Starting the macOS install") {
			try await $0.startMacInstall(vm: name, source: source)
		}
	}

	public func cancelInstall(_ name: String) {
		perform("Canceling the macOS install") { try await $0.cancelMacInstall(vm: name) }
	}
}
