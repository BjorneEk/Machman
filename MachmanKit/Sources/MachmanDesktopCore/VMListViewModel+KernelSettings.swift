//
//  VMListViewModel+KernelSettings.swift
//  MachmanDesktopCore
//
//  Kernel-boot settings writes: the active kernel and initramfs picks, and the VM command
//  line's commit (P41). vm.kernel.update replaces the whole KernelSettings, so a write built
//  from any copy of them undoes whatever changed since the copy was made: a render's copy
//  reverted a pick made while the editor's debounce waited, and even the served copy lags
//  each write by its reply, the agent's listChanged and the next fetch (review F8). So each
//  write is a change, applied to the settings served once the writes before it on that VM
//  have landed and been listed, one at a time, in the order they were asked.
//

import Foundation
import MachmanAPI

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
	// stands in for a VM the list doesn't hold). A change that changes nothing sends nothing;
	// a refused one says so like any request and the next write goes on.
	private func writeKernelSettings(
		_ name: String, fallback: VMInfo? = nil,
		_ change: @escaping @MainActor (inout KernelSettings) -> Void
	) {
		let previous = kernelWrites[name]
		kernelWrites[name] = Task { [weak self] in
			await previous?.value
			guard let self else { return }
			let served = (vms.first { $0.name == name } ?? fallback)?.boot.kernel
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
}
