//
//  VMListViewModel+KernelSettings.swift
//  MachmanDesktopCore
//
//  The VM command line's commit (P41). vm.kernel.update replaces the whole KernelSettings,
//  so a commit built from a render's copy of the VM undid a kernel or initramfs picked
//  while the editor's debounce waited. It names only the VM; the rest is what is served now.
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	public func setKernelCommandLine(_ name: String, _ commandLine: String) {
		guard let vm = vms.first(where: { $0.name == name }) else { return }
		var settings = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		guard settings.commandLine != commandLine else { return }
		settings.commandLine = commandLine
		updateKernelSettings(name, settings)
	}
}
