//
//  RoutingMachman+ConfigRouting.swift
//  MachmanCore
//
//  The per-VM setting changes. Each goes to the process that owns the VM's config
//  (editSettings: refused while an outdated vmhost runs it, held against a start while the
//  daemon makes it), or, where the framework fixes the setting at start, is refused until the
//  VM is stopped (requireStopped): hardware and MAC, disks, mounts, serial ports, kernel boot,
//  run defaults and safety, devices, and Guest Setup.
//

import Foundation
import MachmanAPI

extension RoutingMachman {
	public func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		try await editSettings(name) {
			try await $0.setHardware(
				vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
				nestedVirtualization: nestedVirtualization)
		}
	}

	// Refused while hosted, not proxied: the running guest keeps the old MAC, and conflict
	// tracking captures macInUse at spawn — a mid-run change would desynchronize both.
	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try await requireStopped(name, "regenerating its MAC")
		return try await local.regenerateMAC(vm: name)
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await editSettings(name) {
			try await $0.addDisk(vm: name, disk)
		}
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		// Unlinking the backing file under a live VZ attachment is unsafe — stop first
		// (the guest would keep a ghost disk until shutdown, then the data is gone).
		try await requireStopped(name, "removing its disks")
		try await local.removeDisk(vm: name, diskID: diskID)
	}

	// Import proxies deliberately: it is addDisk with a copy in front — the source is an
	// external file no attachment references, the owned image is NEW, and the config
	// addition is the hosted vmhost's to make (next-boot effect, like addDisk/addMount).
	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		let target = try await settingsOwner(name)
		return try await withClaim(name, .importingDisk, inDaemon: target === local) {
			try await target.importDisk(vm: name, path: path)
		}
	}

	// Refused while hosted, not proxied or deferred: the copy reads an image the live VZ
	// attachment holds open read-write (torn owned copy — copyVM's refusal reason), and the
	// config rewire under that attachment makes the next boot silently switch disks.
	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try await requireStopped(name, "promoting its disks")
		return try await withClaim(name, .promotingDisk, inDaemon: true) {
			try await local.promoteDisk(vm: name, diskID: diskID)
		}
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		// Growing the raw file under a live VZ attachment is unsafe — stop first.
		try await requireStopped(name, "resizing its disks")
		return try await local.resizeDisk(vm: name, diskID: diskID, sizeBytes: sizeBytes)
	}

	public func renameDisk(vm name: String, diskID: String, newName: String) async throws
		-> VMInfo {
		// Moving the raw file under a live VZ attachment is unsafe — stop first.
		try await requireStopped(name, "renaming its disks")
		return try await local.renameDisk(vm: name, diskID: diskID, newName: newName)
	}

	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		try await editSettings(name) {
			try await $0.addMount(vm: name, path: path, tag: tag, kind: kind)
		}
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await editSettings(name) {
			try await $0.removeMount(vm: name, mountID: mountID)
		}
	}

	public func setMountTag(vm name: String, mountID: String, tag: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await editSettings(name) {
			try await $0.setMountTag(vm: name, mountID: mountID, tag: tag)
		}
	}

	public func setMountKind(vm name: String, mountID: String, kind: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await editSettings(name) {
			try await $0.setMountKind(vm: name, mountID: mountID, kind: kind)
		}
	}

	// Serial ports are fixed at VM start, so add/remove is refused while hosted (like MAC), but
	// setSerialLogging proxies to the live bridge.
	public func addConsolePort(vm name: String) async throws {
		try await requireStopped(name, "changing its serial ports")
		try await local.addConsolePort(vm: name)
	}

	public func removeConsolePort(vm name: String) async throws {
		try await requireStopped(name, "changing its serial ports")
		try await local.removeConsolePort(vm: name)
	}

	public func addUartPort(vm name: String) async throws {
		try await requireStopped(name, "changing its serial ports")
		try await local.addUartPort(vm: name)
	}

	public func removeUartPort(vm name: String) async throws {
		try await requireStopped(name, "changing its serial ports")
		try await local.removeUartPort(vm: name)
	}

	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		try await editSettings(name) {
			try await $0.setSerialLogging(
				vm: name, kind: kind, index: index, config: config)
		}
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await editSettings(name) {
			try await $0.setKernelBoot(vm: name, enabled: enabled)
		}
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await editSettings(name) {
			try await $0.updateKernelSettings(vm: name, settings)
		}
	}

	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		let target = try await settingsOwner(name)
		return try await withClaim(name, .importingKernel, inDaemon: target === local) {
			try await target.promoteKernelFile(
				vm: name, role: role, sourcePath: sourcePath, tag: tag)
		}
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try await editSettings(name) {
			try await $0.deleteKernelFile(vm: name, path: path)
		}
	}

	public func renameKernelFile(vm name: String, path: String, tag: String) async throws
		-> VMInfo {
		// The hosted VM's config references the old path — stop first.
		try await requireStopped(name, "renaming its kernel files")
		return try await local.renameKernelFile(vm: name, path: path, tag: tag)
	}

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try await editSettings(name) {
			try await $0.setKernelOverride(
				vm: name, path: path, commandLine: commandLine, overrideEnabled: overrideEnabled)
		}
	}

	public func clearKernelSettings(vm name: String) async throws -> VMInfo {
		// It deletes files in the VM's folder: never under a vmhost, a start or a copy (H54).
		try await requireStopped(name, "removing its kernel settings")
		return try await local.clearKernelSettings(vm: name)
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		// Resolved first: reaching the owner can adopt a host, and with it a safe run.
		try await editSettings(name) { target in
			// Policy has a daemon-side launchd side effect.
			try refuseWhileSafe(name, "Run defaults")
			// C8: never two VMs starting at login on one disk file or MAC. Read from the
			// configs on disk — a hosted VM's policy and disks are its vmhost's, saved there.
			if policy.autostart,
				let conflict = BootGuard.autostartConflict(turningOn: name, library: machmanVMDir) {
				throw conflict
			}
			try await target.setStartPolicy(vm: name, policy: policy)
		}
		// Agent bookkeeping reads the ARGUMENT, never the registry: while the VM is hosted
		// the daemon's config copy is stale until the host exits.
		guard let launchAgents else { return }
		if policy.autostart {
			do {
				try launchAgents.install(vm: name)
			} catch {
				MachmanLogger.log(.passiveError,
					"cannot write launch agent for \(name): \(error)")
			}
		} else {
			launchAgents.remove(vm: name, canBootout: hosted[name] == nil)
		}
	}

	public func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
		try await editSettings(name) {
			try await $0.setSafety(vm: name, disks: disks, mounts: mounts)
		}
	}

	// MARK: - Guest devices (1.0.4) — config-plane edits proxy like disks (next-boot effect).

	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await editSettings(name) {
			try await $0.addDevice(vm: name, kind: kind)
		}
	}

	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await editSettings(name) {
			try await $0.removeDevice(vm: name, kind: kind)
		}
	}

	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		try await editSettings(name) {
			try await $0.updateDevice(vm: name, device: device)
		}
	}

	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?, devices: [String: Bool]?
	) async throws {
		try await editSettings(name) {
			try await $0.setEnabled(
				vm: name, disks: disks, mounts: mounts, console: console, uart: uart,
				devices: devices)
		}
	}

	// MARK: - Guest setup (1.0.7)

	public func resetSetup(vm name: String) async throws -> VMInfo {
		// Config-plane only (no daemon-side effects) — plain proxy, like device edits.
		try await editSettings(name) {
			try await $0.resetSetup(vm: name)
		}
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		// Routed to the vmhost while running: it owns the config there AND does the
		// live fill when serving turns on.
		try await editSettings(name) {
			try await $0.setSetupServed(vm: name, serve: serve)
		}
	}
}
