//
//  VMConfig+Kernel.swift
//  MachmanCore
//
//  Kernel boot: the boot toggle and the kernel draft (the one way settings change), the VM's
//  own kernel files and their re-tagging, re-pointing owned paths when the VM's folder moves or
//  is copied, and the per-file command-line overrides behind the effective command line.
//

import Foundation
import MachmanAPI

// A per-kernel-file command-line override (vm.kernel.setOverride). Persisted in VMConfig
// keyed by the file's VM-relative identity "role/tag/fileName" — stable across VM renames
// and library relocation, unlike the absolute path the wire uses to address files.
struct KernelOverrideConfig: Codable, Equatable {
	var commandLine: String
	var enabled: Bool
}

extension VMConfig {
	var isKernelBoot: Bool {
		if case .linuxKernel = boot { return true }
		return false
	}

	// The kernel-boot checkbox: on -> boot from the persisted kernel draft, off -> EFI.
	// The draft (`kernelSettings`) survives toggling off while it holds something — a file or
	// a command line keeps its value for the next kernel boot — and goes once it holds
	// nothing (N3): an empty draft kept the tree's parked kernel sections for good.
	func setKernelBoot(enabled: Bool) throws {
		let settings = kernelSettings
			?? LinuxKernelBoot(kernelPath: "", initialRamdiskPath: nil, commandLine: "")
		let newBoot: BootConfig = enabled ? .linuxKernel(settings) : .efi
		try BootConfig.validateTransition(from: boot, to: newBoot)
		boot = newBoot
		applyKernelSettings(settings)
		try saveVMConfig()
	}

	// Writes the draft and, when kernel boot is active, keeps the live payload in sync.
	func updateKernelSettings(_ settings: LinuxKernelBoot) throws {
		applyKernelSettings(settings)
		try saveVMConfig()
	}

	// The one way kernel settings change (D21): the draft, and the live boot payload while
	// kernel boot is on — a start reads boot (makeBootLoader), so an edit that missed it
	// would boot the old files. While kernel boot is off a draft that holds nothing goes
	// (N3); while it is on, the draft is what the boot reads and stays. No save; callers
	// batch it into theirs.
	func applyKernelSettings(_ settings: LinuxKernelBoot) {
		kernelSettings = !isKernelBoot && settings.holdsNothing ? nil : settings
		if isKernelBoot { boot = .linuxKernel(settings) }
	}

	// Owned kernel/initramfs files (copies living under <vm>/kernels).
	func kernelsDirPath() -> String { configFilePath(file: "kernels") }

	func ownedKernelFiles() -> [OwnedKernelFile] {
		KernelStore.ownedFiles(
			kernelsDir: kernelsDirPath(),
			kernelPath: kernelSettings?.kernelPath,
			initrdPath: kernelSettings?.initialRamdiskPath)
	}

	// The command line a kernel boot reads (D28): the active kernel file's own override while
	// it is on, else the VM's. The one rule for the boot and for any effective line served.
	func effectiveKernelCommandLine(for boot: LinuxKernelBoot) -> String {
		guard let file = ownedKernelFiles().first(where: {
			$0.role == .kernel && $0.path == boot.kernelPath
		}), let override = kernelOverrides[Self.kernelOverrideKey(for: file)], override.enabled
		else { return boot.commandLine }
		return override.commandLine
	}

	// How the VM directory changed: moved (rename, promotion — the files are now only at
	// the new place) or copied (vm.copy, safe-run shadowing — the source keeps its files).
	enum OwnedPathChange {
		case moved
		case copied
	}

	// Owned paths are absolute and embed the VM directory, so every operation that moves or
	// copies that directory must re-point them, or the config keeps using the old location's
	// files (C1, C12): the kernel and initramfs, owned (imported) isos, and — on a move only —
	// fromUrl entries naming a file inside the folder. A copy keeps its fromUrl references on
	// the source's files: that is VMCopier's reference rule, and a safe-run shadow's unsafe
	// disks MUST keep naming the real files. External paths (never under the old directory)
	// stay put. Mounts are never touched. No save — callers batch it into theirs.
	func rewriteOwnedPaths(
		fromDir oldDir: String, toDir newDir: String, _ change: OwnedPathChange
	) {
		func moved(_ path: String?) -> String? {
			guard let path, path.hasPrefix(oldDir + "/") else { return nil }
			return newDir + String(path.dropFirst(oldDir.count))
		}
		for index in disks.indices {
			switch disks[index].kind {
			case .iso(let url):
				if let path = moved(url.path) {
					disks[index].kind = .iso(URL(fileURLWithPath: path))   // flags stay
				}
			case .fromUrl(let url) where change == .moved:
				if let path = moved(url.path) {
					disks[index].kind = .fromUrl(URL(fileURLWithPath: path))
				}
			case .storage, .fromUrl:
				break
			}
		}
		guard var settings = kernelSettings else { return }
		var changed = false
		if let path = moved(settings.kernelPath) {
			settings.kernelPath = path
			changed = true
		}
		if let path = moved(settings.initialRamdiskPath) {
			settings.initialRamdiskPath = path
			changed = true
		}
		guard changed else { return }
		applyKernelSettings(settings)
	}

	// After deleting an owned kernel file, clear any kernel field that pointed at it (a
	// parked draft left holding nothing goes with it, applyKernelSettings).
	func clearKernelReference(to path: String) throws {
		guard var settings = kernelSettings else { return }
		var changed = false
		if settings.kernelPath == path { settings.kernelPath = ""; changed = true }
		if settings.initialRamdiskPath == path { settings.initialRamdiskPath = nil; changed = true }
		if changed {
			applyKernelSettings(settings)
			try saveVMConfig()
		}
	}

	// Re-tag an owned kernel/initramfs file: moves it on disk and migrates the kernel-boot
	// references and the per-file override to the new path/key. Returns the new path. A
	// failed save re-tags the file back (D22's shape: the config still names the old path).
	@discardableResult
	func renameKernelFile(path: String, to newTag: String) throws -> String {
		// KernelStore moves the standardized path, so every comparison here uses it too (a
		// wire path may carry "." or "..").
		let oldPath = URL(fileURLWithPath: path).standardized.path
		let newPath = try KernelStore.rename(
			path: path, kernelsDir: kernelsDirPath(), newTag: newTag)
		guard newPath != oldPath else { return newPath }
		let before = (kernelSettings, boot, kernelOverrides)
		func isOld(_ reference: String?) -> Bool {
			guard let reference, !reference.isEmpty else { return false }
			return URL(fileURLWithPath: reference).standardized.path == oldPath
		}
		if var settings = kernelSettings {
			var changed = false
			if isOld(settings.kernelPath) {
				settings.kernelPath = newPath
				changed = true
			}
			if isOld(settings.initialRamdiskPath) {
				settings.initialRamdiskPath = newPath
				changed = true
			}
			if changed { applyKernelSettings(settings) }
		}
		// The override follows the file to the key its NEW path names — KernelStore's
		// normalized tag, never one rebuilt from the raw text.
		if let oldKey = VMConfig.kernelOverrideKey(forPath: oldPath),
			let newKey = VMConfig.kernelOverrideKey(forPath: newPath),
			let value = kernelOverrides.removeValue(forKey: oldKey) {
			kernelOverrides[newKey] = value
		}
		do {
			try saveVMConfig()
		} catch {
			(kernelSettings, boot, kernelOverrides) = before
			let oldTag = URL(fileURLWithPath: oldPath).deletingLastPathComponent()
				.lastPathComponent
			do {
				_ = try KernelStore.rename(
					path: newPath, kernelsDir: kernelsDirPath(), newTag: oldTag)
			} catch let moveBack {
				MachmanLogger.log(.passiveError,
					"\(name): \(newPath) couldn’t move back to its tag \(oldTag): \(moveBack)")
			}
			throw error
		}
		return newPath
	}

	// MARK: - Kernel overrides (vm.kernel.setOverride)

	// The wire addresses kernel overrides by absolute file path; the config keys them by the
	// stable VM-relative identity.
	static func kernelOverrideKey(for file: OwnedKernelFile) -> String {
		"\(file.role.rawValue)/\(file.tag)/\(file.fileName)"
	}

	// The same key read off an owned file's path: its last three components
	// (<kernelsDir>/<role>/<tag>/<fileName>). nil for a path too short to carry one.
	static func kernelOverrideKey(forPath path: String) -> String? {
		let components = (path as NSString).pathComponents.suffix(3)
		guard components.count == 3 else { return nil }
		return components.joined(separator: "/")
	}

	// nil fields leave that half unchanged; the override entry persists even while disabled
	// so the text survives toggling.
	func setKernelOverride(forFileAt path: String, commandLine: String?, enabled: Bool?) throws {
		guard let file = ownedKernelFiles().first(where: { $0.path == path }) else {
			throw MachmanError(
				code: .notFound, message: "\(name) no longer has that kernel file")
		}
		let key = VMConfig.kernelOverrideKey(for: file)
		var override = kernelOverrides[key]
			?? KernelOverrideConfig(commandLine: "", enabled: false)
		if let commandLine { override.commandLine = commandLine }
		if let enabled { override.enabled = enabled }
		kernelOverrides[key] = override
		try saveVMConfig()
	}

	// Deleting an owned kernel file drops its override.
	func pruneKernelOverride(forDeletedPath path: String) {
		guard let key = VMConfig.kernelOverrideKey(forPath: path) else { return }
		if kernelOverrides.removeValue(forKey: key) != nil {
			try? saveVMConfig()
		}
	}
}

extension LinuxKernelBoot {
	// The wire's content rule for a draft (KernelSettings.holdsNothing, K1): no file and no
	// command line.
	var holdsNothing: Bool {
		KernelSettings(
			kernelPath: kernelPath, initrdPath: initialRamdiskPath, commandLine: commandLine
		).holdsNothing
	}
}
