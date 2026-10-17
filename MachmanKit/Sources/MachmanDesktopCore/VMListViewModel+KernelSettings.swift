//
//  VMListViewModel+KernelSettings.swift
//  MachmanDesktopCore
//
//  Kernel boot's requests: the active kernel and initramfs picks and the VM command line's
//  commit (P41), the kernel files' promote, re-tag and delete, the boot toggle and the
//  per-file overrides. vm.kernel.update replaces the whole KernelSettings, so a write built
//  from any copy of them undoes whatever changed since the copy was made: a render's copy
//  reverted a pick made while the editor's debounce waited, and even the served copy lags
//  each write by its reply, the agent's listChanged and the next fetch (review F8). So each
//  write is a change, applied to the settings served once the writes before it on that VM
//  have landed and been listed, one at a time, in the order they were asked. A promote,
//  re-tag or delete changes the settings daemon-side too (the file it adds becomes active,
//  the path it moves or removes is rewritten), so it takes its turn in the same queue (P43).
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMListViewModel {
	// Select or deselect an active kernel or initramfs file by rewiring the kernel-boot draft
	// (the settings survive as a draft even while the mode is EFI: never toggles the mode).
	public func setActiveKernelFile(_ vm: VMInfo, role: KernelRole, path: String?) {
		guard role != .unknown else { return }   // decode fallback only: the tree never builds it
		writeKernelSettings(vm.name, fallback: vm) { settings in
			if role == .kernel {
				settings.kernelPath = path ?? ""
			} else {
				settings.initrdPath = path
			}
		}
	}

	// The command line's commit names only the VM: it lands up to 600 ms after the render
	// that started it.
	public func setKernelCommandLine(_ name: String, _ commandLine: String) {
		writeKernelSettings(name) { $0.commandLine = commandLine }
	}

	// The whole settings, as given (the change most writes make is narrower).
	public func updateKernelSettings(_ name: String, _ settings: KernelSettings) {
		writeKernelSettings(name) { $0 = settings }
	}

	// `change` applied to what is served once this VM's earlier writes are listed (`fallback`
	// stands in for a VM the list doesn't hold). A VM gone from the list by then (deleted, or
	// renamed, while the editor's commit waited) gets nothing, and neither does a change that
	// changes nothing; a refused one says so like any request and the next write goes on.
	private func writeKernelSettings(
		_ name: String, fallback: VMInfo? = nil,
		_ change: @escaping @MainActor (inout KernelSettings) -> Void
	) {
		enqueueKernelWrite(name) { model in
			guard let vm = model.vms.first(where: { $0.name == name }) ?? fallback else {
				return false
			}
			// Empty only for a VM with no kernel settings yet.
			let served = vm.boot.kernel
				?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
			var settings = served
			change(&settings)
			guard settings != served else { return false }
			let sent: Void? = await model.attempt("Saving kernel settings") {
				try await $0.updateKernelSettings(vm: name, settings)
			}
			return sent != nil
		}
	}

	// The VM's kernel writes, one at a time in the order asked: `write` runs once the one
	// before it has landed, and one that went through (true) reloads the list before the next
	// starts, so every write starts from what was served after the last.
	private func enqueueKernelWrite(
		_ name: String, _ write: @escaping @MainActor (VMListViewModel) async -> Bool
	) {
		let previous = kernelWrites[name]
		kernelWrites[name] = Task { [weak self] in
			await previous?.value
			guard let self, await write(self) else { return }
			await store.reload()
		}
	}

	// MARK: - Kernel files, boot toggle and overrides

	public func requestDeleteKernel(_ name: String, path: String, fileName: String) {
		pendingKernelDelete = PendingKernelDelete(vm: name, path: path, fileName: fileName)
	}

	// The file's path changes with its tag — repoint a selection that was on the old path.
	// `refused` takes a refusal to the field instead of an alert. In the VM's write queue.
	public func renameKernelTag(
		_ name: String, path: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		let fileName = (path as NSString).lastPathComponent
		enqueueKernelWrite(name) { model in
			guard let updated = await model.attempt("Renaming a kernel file", refused: refused, {
				try await $0.renameKernelFile(vm: name, path: path, tag: tag)
			}) else { return false }
			// Said only once the reply holds the file under its new tag.
			guard let file = updated.boot.ownedKernels?.first(where: {
				$0.tag == tag && $0.fileName == fileName
			}) else { return true }
			let old: SidebarNode = file.role == .kernel ? .kernel(path) : .initramfs(path)
			if model.treeSelection == [old] {
				model.treeSelection = [file.role == .kernel
					? .kernel(file.path) : .initramfs(file.path)]
			}
			model.pushToast(
				symbol: MachmanSymbols.rename,
				message: ToastWording.renamed(to: tag))
			return true
		}
	}

	// The copied file becomes the role's active one daemon-side. In the VM's write queue.
	public func promoteKernel(_ name: String, role: KernelRole, sourcePath: String, tag: String) {
		enqueueKernelWrite(name) { model in
			await model.attempt("Promoting a kernel file") {
				try await $0.promoteKernelFile(
					vm: name, role: role, sourcePath: sourcePath, tag: tag)
			} != nil
		}
	}

	// A field naming the file is cleared daemon-side. In the VM's write queue.
	public func deleteKernel(_ name: String, path: String) {
		enqueueKernelWrite(name) { model in
			await model.attempt("Deleting a kernel file") {
				try await $0.deleteKernelFile(vm: name, path: path)
			} != nil
		}
	}

	public func setKernelBoot(_ name: String, enabled: Bool) async -> Bool {
		let switched: Void? = await attempt("Switching boot mode") {
			try await $0.setKernelBoot(vm: name, enabled: enabled)
		}
		return switched != nil
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

	// MARK: - Removing a parked kernel draft (H54, K2)

	// The one question Remove Kernel Settings… asks, naming the VM and how many of its own
	// kernel files go (an external reference is only dropped, never deleted).
	public struct PendingKernelClear: Identifiable {
		public let id = UUID()
		public let vm: String
		public let fileCount: Int

		public var title: String {
			switch fileCount {
			case 0: return "Remove \(vm)’s kernel settings?"
			case 1: return "Remove \(vm)’s kernel settings and its kernel file?"
			default: return "Remove \(vm)’s kernel settings and its \(fileCount) kernel files?"
			}
		}

		// The kernel-delete question's sentence; nothing to say without files.
		public var message: String? {
			fileCount == 0
				? nil : "The files belong to \(vm) and are removed from its directory."
		}
	}

	public func requestClearKernelSettings(_ vm: VMInfo) {
		pendingKernelClear = PendingKernelClear(
			vm: vm.name, fileCount: vm.boot.ownedKernels?.count ?? 0)
	}

	// What an older Machman Agent's -32601 for vm.kernel.clear becomes: what to do.
	public static let kernelClearNeedsNewerAgent = "The running Machman Agent is too old to "
		+ "remove kernel settings — quit it from its menu-bar item to update it"

	// The draft, the VM's kernel files and their overrides in one daemon call, in the VM's
	// write queue; the reloaded list hides the sections, and the selection prune follows.
	public func clearKernelSettings(_ name: String) {
		enqueueKernelWrite(name) { model in
			let cleared: VMInfo? = await model.attempt("Removing kernel settings") { api in
				do {
					return try await api.clearKernelSettings(vm: name)
				} catch let error as MachmanError where error.code == .unsupported {
					throw MachmanError(code: .unsupported, message: Self.kernelClearNeedsNewerAgent)
				}
			}
			guard cleared != nil else { return false }
			model.pushToast(symbol: MachmanSymbols.kernelFile, message: "Removed kernel settings")
			return true
		}
	}
}
