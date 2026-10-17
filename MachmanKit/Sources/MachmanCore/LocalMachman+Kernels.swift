//
//  LocalMachman+Kernels.swift
//  MachmanCore
//
//  Kernel boot (vm.kernel.*): the boot toggle and the kernel draft, importing, renaming and
//  deleting the VM's own kernel files, and per-file command-line overrides.
//

import Foundation
import MachmanAPI

extension LocalMachman {
	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		let vm = try lookup(name)
		do {
			try vm.config.setKernelBoot(enabled: enabled)
		} catch is BootConfigError {
			throw MachmanError(
				code: .invalidState,
				message: "This VM has macOS installed, so its boot mode can’t change")
		}
		registry.events.emit(.listChanged)
	}

	// An empty initramfs path from the wire is stored as none (D37).
	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		let vm = try lookup(name)
		try vm.config.updateKernelSettings(LinuxKernelBoot(
			kernelPath: settings.kernelPath,
			initialRamdiskPath: settings.initrdPath.flatMap { $0.isEmpty ? nil : $0 },
			commandLine: settings.commandLine))
		registry.events.emit(.listChanged)
	}

	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		guard role != .unknown else {
			throw MachmanError(code: .invalidArgument, message: "Unknown kernel role")
		}
		let vm = try lookup(name)
		let kernelsDir = vm.config.kernelsDirPath()
		// Copies can be tens of MiB — detach so the main actor doesn't freeze. Indeterminate
		// operation (KernelStore reports no byte progress); previously fully silent.
		let opID = operationCenter.begin(
			kind: OperationInfo.Kind.kernelImport, vm: name,
			label: "Importing \(role.rawValue) \u{201C}\(tag)\u{201D}")
		let dest: String
		do {
			dest = try await Task.detached(priority: .userInitiated) {
				try KernelStore.promote(
					role: role, sourcePath: sourcePath, kernelsDir: kernelsDir, tag: tag)
			}.value
		} catch {
			operationCenter.finish(
				opID, state: OperationInfo.State.failed,
				message: MachmanError.userMessage(for: error))
			throw error
		}
		operationCenter.finish(opID, state: OperationInfo.State.succeeded)
		var updated = vm.config.kernelSettings
			?? LinuxKernelBoot(kernelPath: "", initialRamdiskPath: nil, commandLine: "")
		switch role {
		case .kernel: updated.kernelPath = dest
		case .initramfs: updated.initialRamdiskPath = dest
		case .unknown: break   // rejected on entry above
		}
		try vm.config.updateKernelSettings(updated)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func renameKernelFile(vm name: String, path: String, tag: String)
		async throws -> VMInfo {
		let vm = try lookup(name)
		guard !vm.state.isRunning else {
			throw MachmanError(
				code: .invalidState, message: "Stop \(name) before renaming its kernel files")
		}
		try vm.config.renameKernelFile(path: path, to: tag)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		let vm = try lookup(name)
		let kernelsDir = vm.config.kernelsDirPath()
		// Only a file the VM lists as owned can be deleted over the wire ("..": resolved).
		let wanted = URL(fileURLWithPath: path).standardized.path
		guard let owned = vm.config.ownedKernelFiles().first(where: { $0.path == wanted })
		else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that kernel file")
		}
		let ownedPath = owned.path
		try await Task.detached(priority: .userInitiated) {
			try KernelStore.delete(path: ownedPath, kernelsDir: kernelsDir)
		}.value
		try vm.config.clearKernelReference(to: ownedPath)
		vm.config.pruneKernelOverride(forDeletedPath: ownedPath)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func clearKernelSettings(vm name: String) async throws -> VMInfo {
		let vm = try lookup(name)
		guard !vm.state.isRunning else {
			throw MachmanError(
				code: .invalidState, message: "Stop \(name) before removing its kernel settings")
		}
		defer { registry.events.emit(.listChanged) }
		try vm.config.clearKernelSettings()
		return info(for: vm)
	}

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.setKernelOverride(
			forFileAt: path, commandLine: commandLine, enabled: overrideEnabled)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}
}
