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
//  have landed and been listed, one at a time, in the order they were asked.
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
		let previous = kernelWrites[name]
		kernelWrites[name] = Task { [weak self] in
			await previous?.value
			guard let self, let vm = vms.first(where: { $0.name == name }) ?? fallback
			else { return }
			// Empty only for a VM with no kernel settings yet.
			let served = vm.boot.kernel
				?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
			var settings = served
			change(&settings)
			guard settings != served else { return }
			let sent: Void? = await attempt("Saving kernel settings") {
				try await $0.updateKernelSettings(vm: name, settings)
			}
			if sent != nil { await store.reload() }
		}
	}

	// MARK: - Kernel files, boot toggle and overrides

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
}
