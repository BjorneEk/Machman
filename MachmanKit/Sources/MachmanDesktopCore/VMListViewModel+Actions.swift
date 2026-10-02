//
//  VMListViewModel+Actions.swift
//  MachmanDesktopCore
//
//  What the user asks of the daemon: every request a view, a menu or the Dock sends, with
//  the question that confirms it first when it destroys something (request →
//  confirmationDialog → perform), sectioned by what it acts on.
//

import Foundation
import MachmanUI
import MachmanAPI

extension VMListViewModel {
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
		Task { [weak self] in
			do {
				try await self?.api.openWindow(vm: name)
			} catch {
				self?.present(error, while: "Opening the \u{201C}\(name)\u{201D} window")
			}
		}
	}

	public func closeWindow(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.closeWindow(vm: name)
			} catch {
				self?.present(error, while: "Closing the \u{201C}\(name)\u{201D} window")
			}
		}
	}

	public func stopVM(_ name: String, mode: StopMode = .force) {
		Task { [weak self] in
			do {
				try await self?.api.stop(vm: name, mode: mode)
			} catch {
				let action = mode == .soft ? "Shutting down" : "Force stopping"
				self?.present(error, while: "\(action) \u{201C}\(name)\u{201D}")
			}
		}
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
		Task { [weak self] in
			do {
				try await self?.api.deleteVM(named: vm.name)
				// The picker can delete a VM that isn't the shown one — keep the selection
				// unless it was the one deleted.
				if self?.selectedName == vm.name {
					self?.select(name: nil)
				}
			} catch {
				self?.present(error, while: "Deleting \u{201C}\(vm.name)\u{201D}")
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
		Task { [weak self] in
			do {
				try await self?.api.setHardware(
					vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
					nestedVirtualization: nested)
			} catch {
				self?.present(error, while: "Updating hardware for \u{201C}\(name)\u{201D}")
			}
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
		Task { [weak self] in
			do {
				try await self?.api.setStartPolicy(vm: name, policy: policy)
			} catch {
				self?.present(
					error, while: "Updating the default start for \u{201C}\(name)\u{201D}")
			}
		}
	}

	public func regenerateMAC(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.regenerateMAC(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.regenerate, message: "MAC address regenerated")
			} catch {
				self?.present(error, while: "Regenerating the MAC address")
			}
		}
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
		Task { [weak self] in
			do {
				_ = try await self?.api.importDisk(vm: name, path: path)
			} catch {
				self?.present(error, while: "Importing a disk into \u{201C}\(name)\u{201D}")
			}
		}
	}

	public func promoteDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteDisk(vm: name, diskID: diskID)
			} catch {
				self?.present(error, while: "Promoting a disk on \u{201C}\(name)\u{201D}")
			}
		}
	}

	// The disk id derives from the name, so a successful rename repoints a selection that
	// was on the old id (the inspector would otherwise go blank). `refused` takes a refusal
	// to the field instead of an alert.
	public func renameDisk(
		_ name: String, diskID: String, newName: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		Task { [weak self] in
			do {
				guard let updated = try await self?.api.renameDisk(
					vm: name, diskID: diskID, newName: newName) else { return }
				if self?.treeSelection == [.disk(diskID)],
					let newID = updated.disks.first(where: { $0.name == newName })?.id {
					self?.treeSelection = [.disk(newID)]
				}
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: ToastWording.renamed(to: newName))
			} catch {
				self?.refuse(error, while: "Renaming a disk", to: refused)
			}
		}
	}

	public func resizeDisk(_ name: String, diskID: String, sizeBytes: UInt64) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resizeDisk(
					vm: name, diskID: diskID, sizeBytes: sizeBytes)
				self?.pushToast(
					symbol: MachmanSymbols.diskSize,
					message: "Disk grown to \(ByteSize.display(sizeBytes))")
			} catch {
				self?.present(error, while: "Growing a disk")
			}
		}
	}

	public func setDiskSafety(_ name: String, diskID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: [diskID: safe], mounts: nil)
			} catch {
				self?.present(error, while: "Updating disk safety")
			}
		}
	}

	public func addDisk(_ name: String, _ disk: NewDisk) {
		Task { [weak self] in
			do {
				try await self?.api.addDisk(vm: name, disk)
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Added disk")
			} catch {
				self?.present(error, while: "Adding a disk")
			}
		}
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
		Task { [weak self] in
			do {
				try await self?.api.removeDisk(vm: name, diskID: diskID)
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Removed disk")
			} catch {
				self?.present(error, while: "Removing a disk")
			}
		}
	}

	// MARK: - Mounts

	public func addMount(_ name: String, path: String, tag: String, kind: String? = nil) {
		// Every drop, paste and picker passes the folder's name: one the mount-tag rule
		// refuses (.config, a:b) mounts under a cleaned tag the user can rename.
		let rule = NameRule.mountTag
		let tag = rule.problem(rule.trimmed(tag)) == nil
			? tag : rule.suggestion(from: tag, fallback: "share")
		Task { [weak self] in
			do {
				try await self?.api.addMount(vm: name, path: path, tag: tag, kind: kind)
				self?.pushToast(
					symbol: MachmanSymbols.mount, message: "Added mount \u{201C}\(tag)\u{201D}")
			} catch {
				self?.present(error, while: "Adding a mount")
			}
		}
	}

	public func removeMount(_ name: String, mountID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeMount(vm: name, mountID: mountID)
				self?.pushToast(symbol: MachmanSymbols.mount, message: "Removed mount")
			} catch {
				self?.present(error, while: "Removing a mount")
			}
		}
	}

	public func setMountTag(
		_ name: String, mountID: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setMountTag(vm: name, mountID: mountID, tag: tag)
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: ToastWording.renamed(to: tag))
			} catch {
				self?.refuse(error, while: "Changing a mount tag", to: refused)
			}
		}
	}

	public func setMountKind(_ name: String, mountID: String, kind: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setMountKind(vm: name, mountID: mountID, kind: kind)
			} catch {
				self?.present(error, while: "Changing a mount’s kind")
			}
		}
	}

	public func setMountSafety(_ name: String, mountID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: nil, mounts: [mountID: safe])
			} catch {
				self?.present(error, while: "Updating mount safety")
			}
		}
	}

	// MARK: - Devices and serial ports

	public func addDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.addDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Added \(kind.inlineLabel)")
			}
			catch { self?.present(error, while: "Adding a device") }
		}
	}

	public func removeDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.removeDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Removed \(kind.inlineLabel)")
			}
			catch { self?.present(error, while: "Removing a device") }
		}
	}

	public func updateDevice(_ name: String, device: DeviceInfo) {
		Task { [weak self] in
			do { _ = try await self?.api.updateDevice(vm: name, device: device) }
			catch { self?.present(error, while: "Updating a device") }
		}
	}

	public func addConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Added console port")
			}
			catch { self?.present(error, while: "Adding a console port") }
		}
	}

	public func removeConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Removed console port")
			}
			catch { self?.present(error, while: "Removing a console port") }
		}
	}

	public func addUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addUartPort(vm: name)
				self?.pushToast(symbol: MachmanSymbols.serialUart, message: "Added UART port")
			}
			catch { self?.present(error, while: "Adding a UART port") }
		}
	}

	public func removeUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeUartPort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialUart, message: "Removed UART port")
			}
			catch { self?.present(error, while: "Removing a UART port") }
		}
	}

	public func setSerialLogging(
		_ name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) {
		Task { [weak self] in
			do {
				try await self?.api.setSerialLogging(
					vm: name, kind: kind, index: index, config: config)
			} catch {
				self?.present(error, while: "Updating serial logging")
			}
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
		Task { [weak self] in
			do {
				try await self?.api.setEnabled(
					vm: name, disks: disks, mounts: mounts, console: console, uart: uart,
					devices: devices)
			} catch {
				self?.present(error, while: "Updating enabled state")
			}
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
		Task { [weak self] in
			do {
				guard let updated = try await self?.api.renameKernelFile(
					vm: name, path: path, tag: tag) else { return }
				guard let file = updated.boot.ownedKernels?.first(where: {
					$0.tag == tag && $0.fileName == fileName
				}) else { return }
				let old: SidebarNode = file.role == .kernel ? .kernel(path) : .initramfs(path)
				if self?.treeSelection == [old] {
					self?.treeSelection = [file.role == .kernel
						? .kernel(file.path) : .initramfs(file.path)]
				}
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: ToastWording.renamed(to: tag))
			} catch {
				self?.refuse(error, while: "Renaming a kernel file", to: refused)
			}
		}
	}

	public func promoteKernel(_ name: String, role: KernelRole, sourcePath: String, tag: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteKernelFile(
					vm: name, role: role, sourcePath: sourcePath, tag: tag)
			} catch {
				self?.present(error, while: "Promoting a kernel file")
			}
		}
	}

	public func deleteKernel(_ name: String, path: String) {
		Task { [weak self] in
			do { _ = try await self?.api.deleteKernelFile(vm: name, path: path) }
			catch { self?.present(error, while: "Deleting a kernel file") }
		}
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
		Task { [weak self] in
			do {
				_ = try await self?.api.setKernelOverride(
					vm: name, path: path, commandLine: commandLine,
					overrideEnabled: overrideEnabled)
			} catch {
				self?.present(error, while: "Updating the kernel override")
			}
		}
	}

	public func updateKernelSettings(_ name: String, _ settings: KernelSettings) {
		Task { [weak self] in
			do {
				try await self?.api.updateKernelSettings(vm: name, settings)
			} catch {
				self?.present(error, while: "Saving kernel settings")
			}
		}
	}

	// MARK: - SSH and guest setup (1.0.5)

	// A failure is titled by what the toggle did: added or removed the alias.
	public func setSSHIntegration(_ name: String, enabled: Bool) {
		let alias = vms.first { $0.name == name }.map(SSHCommand.hostKeyAlias(for:))
			?? SSHAliasRule.defaultAlias(for: name)
		let action = enabled
			? "Adding \u{201C}\(alias)\u{201D} to your SSH config"
			: "Removing \u{201C}\(alias)\u{201D} from your SSH config"
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: enabled, reverseApproved: nil, alias: nil)
			}
			catch { self?.present(error, while: action) }
		}
	}

	// An empty alias resets the VM to its default "<vm>.machman" name.
	public func setSSHAlias(_ name: String, alias: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: nil, reverseApproved: nil, alias: alias)
			}
			catch { self?.present(error, while: "Renaming the SSH alias") }
		}
	}

	// Deny answers a pending request; Revoke takes back an approved key.
	public func setSSHReverseApproved(_ name: String, approved: Bool) {
		let wasPending = vms.first { $0.name == name }?.ssh?.reverseState == .pending
		let verb = approved ? "Approved" : wasPending ? "Denied" : "Revoked"
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: nil, reverseApproved: approved, alias: nil)
				self?.pushToast(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "\(verb) \(name)’s access to this Mac")
			}
			catch { self?.present(error, while: "Updating guest access") }
		}
	}

	// Re-run Address Discovery and Check Connection: a spinner toast, then what it found —
	// even an unchanged address (F4).
	public func refreshSSH(_ name: String) {
		beginRediscovery(name)
		Task { [weak self] in
			do {
				try await self?.api.refreshSSH(vm: name)
			} catch {
				self?.endRediscovery(name)
				self?.present(error, while: "Looking for the address of \u{201C}\(name)\u{201D}")
			}
		}
	}

	public func resetSSH(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resetSSH(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "SSH state reset for \(name)")
			}
			catch { self?.present(error, while: "Resetting SSH state") }
		}
	}

	public func resetSetup(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resetSetup(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.deviceGuestSetup,
					message: "Guest setup state reset for \(name)")
			}
			catch { self?.present(error, while: "Resetting guest setup state") }
		}
	}

	// The Allow-reinstall toggle made real: serving on demand, clean share otherwise.
	public func setSetupServed(_ name: String, serve: Bool) {
		Task { [weak self] in
			do { _ = try await self?.api.setSetupServed(vm: name, serve: serve) }
			catch { self?.present(error, while: "Changing the reinstall setting") }
		}
	}

	// MARK: - macOS install

	public func startInstall(_ name: String, source: InstallSource) {
		Task { [weak self] in
			do {
				try await self?.api.startMacInstall(vm: name, source: source)
			} catch {
				self?.present(error, while: "Starting the macOS install")
			}
		}
	}

	public func cancelInstall(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.cancelMacInstall(vm: name)
			} catch {
				self?.present(error, while: "Canceling the macOS install")
			}
		}
	}
}
