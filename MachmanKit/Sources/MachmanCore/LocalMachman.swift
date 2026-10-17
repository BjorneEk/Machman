//
//  LocalMachman.swift
//  Machman
//
//  The engine's implementation of MachmanControlling: a straight passthrough from the API seam
//  to VMRegistry, mapping engine types to DTOs. Each vmhost serves one for its VM, and the
//  daemon keeps one behind RoutingMachman for the VMs no vmhost runs; clients reach either only
//  over a socket.
//
//  This file holds the host, lifecycle, configuration, SSH, run and install calls; beside it
//  are LocalMachman+Disks, +Devices, +Kernels and +VMInfo (the config → wire mapping).
//

import Foundation
import AppKit
import Virtualization
import MachmanAPI

@MainActor
public final class LocalMachman: MachmanControlling {
	let registry: VMRegistry
	// Long-running-operation registry (host.operations / op.cancel / operationChanged).
	// Internal so RoutingMachman can register its daemon-side operations (shadow builds,
	// Rosetta installs) in the same place.
	let operationCenter: OperationCenter

	public init(registry: VMRegistry) {
		self.registry = registry
		self.operationCenter = OperationCenter(events: registry.events)
	}

	// MARK: - Host

	public func hostCapabilities() async throws -> HostCapabilities {
		var freeDiskBytes: UInt64 = 0
		let url = URL(fileURLWithPath: machmanVMDir)
		if let values = try? url.resourceValues(
			forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
			let available = values.volumeAvailableCapacityForImportantUsage {
			freeDiskBytes = UInt64(available)
		}
		let screen = VMConfig.mainScreenSize(2560, 1440)
		return HostCapabilities(
			maxCPUCount: VMConfig.computeMaxCPUCount(),
			minMemoryBytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
			maxMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize,
			freeDiskBytes: freeDiskBytes,
			uartUnavailable: VMConfig.uartUnavailability(),
			nestedVirtualizationSupported:
				VZGenericPlatformConfiguration.isNestedVirtualizationSupported,
			rosettaAvailability: Self.rosettaAvailabilityString(),
			hostDisplayWidthPixels: screen.width,
			hostDisplayHeightPixels: screen.height,
			maxSerialPorts: VMConfig.maxSerialPorts)
	}

	private static func rosettaAvailabilityString() -> String {
		switch VZLinuxRosettaDirectoryShare.availability {
		case .notSupported: return RosettaAvailability.notSupported
		case .notInstalled: return RosettaAvailability.notInstalled
		case .installed: return RosettaAvailability.installed
		@unknown default: return RosettaAvailability.notSupported
		}
	}

	// MARK: - VM lifecycle

	public func listVMs() async throws -> [VMInfo] {
		registry.list().map { info(for: $0) }
	}

	public func vm(named name: String) async throws -> VMInfo {
		info(for: try lookup(name))
	}

	public func createVM(template: VMTemplate?) async throws -> VMInfo {
		let vm = try registry.create()
		try Self.applyTemplate(template, to: vm.config)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The whole meaning of a createVM template, as a sync seam (tests pin it without the
	// async surface). nil keeps the pre-template behavior — same seeding as .default.
	static func applyTemplate(_ template: VMTemplate?, to config: VMConfig) throws {
		switch template {
		case .blank:
			// Truly blank: no devices AND no seeded console port — add exactly what you need.
			config.devices = []
			config.consolePorts = []
			try config.saveVMConfig()
		case .mac:
			// Trackpad needs macOS boot — addable once macOS is installed; keyboard/pointer
			// resolve to the boot-appropriate VZ class at assembly.
			config.devices = ImpliedDevices.kinds(macGuest: true)
				.filter { $0 != .trackpad }
				.map(GuestDevice.init)
			try config.saveVMConfig()
		case .default, nil:
			break   // the implied EFI device set is already seeded; no disk
		}
	}

	public func deleteVM(named name: String) async throws {
		try registry.delete(try lookup(name))
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try registry.rename(try lookup(name), to: newName)
	}

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, mountIDs: [String]?,
		regenerateMAC: Bool
	) async throws -> VMInfo {
		let vm = try lookup(name)
		guard !vm.state.isRunning else {
			throw MachmanError(code: .invalidState, message: "Stop \(name) before copying it")
		}
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState, message: "Wait for the macOS install to finish first")
		}
		let target: String
		if let newName {
			try registry.checkNewVMName(newName)
			target = newName
		} else {
			target = registry.uniqueName(base: "\(name) copy")
		}
		let events = registry.events
		let center = operationCenter
		let cancelFlag = CancelFlag()
		let opID = center.begin(
			kind: OperationInfo.Kind.copyVM, vm: target,
			label: Self.copyLabel(source: name), cancel: { cancelFlag.set() })
		var request = Self.copyRequest(
			from: vm.config, sourceDir: machmanVMDir + "/" + name,
			destinationParent: machmanVMDir, newName: target, diskIDs: diskIDs,
			mountIDs: mountIDs, regenerateMAC: regenerateMAC)
		request.progress = { copied, total in
			Task { @MainActor in
				events.emit(.copyProgress(vm: target, copiedBytes: copied, totalBytes: total))
				center.update(
					opID, fraction: total > 0 ? Double(copied) / Double(total) : nil,
					completedBytes: Int64(copied), totalBytes: Int64(total))
			}
		}
		request.isCancelled = { cancelFlag.get() }
		// Synchronous file work would freeze the main actor for the whole clone — detach it.
		// The staging rename inside the copier arbitrates any name minted while we waited.
		do {
			try await Task.detached(priority: .userInitiated) {
				try VMCopier.copy(request)
			}.value
		} catch {
			center.finish(
				opID,
				state: cancelFlag.get()
					? OperationInfo.State.cancelled : OperationInfo.State.failed,
				message: MachmanError.userMessage(for: error))
			throw error
		}
		center.finish(opID, state: OperationInfo.State.succeeded)
		return info(for: try registry.adoptFromDisk(name: target))
	}

	// A copy's progress label. The operation's vm is the copy being made, and clients title
	// the card "<vm> — <label>", so the label names only the source (F8).
	static func copyLabel(source: String) -> String {
		"Copying from \(source)"
	}

	// What vm.copy hands the copier, as a sync seam (tests pin it without the async shell):
	// writable disks by diskIDs (nil = all; storage clones, image references), ISOs always
	// by reference, mounts by mountIDs (nil = all), and the guest kind from the boot mode.
	static func copyRequest(
		from config: VMConfig, sourceDir: String, destinationParent: String, newName: String,
		diskIDs: [String]?, mountIDs: [String]?, regenerateMAC: Bool
	) -> VMCopyRequest {
		let included = diskIDs.map(Set.init)
		var policies: [String: VMCopyRequest.DiskPolicy] = [:]
		for disk in config.disks {
			switch disk.kind {
			case .storage:
				policies[disk.id] = (included?.contains(disk.id) ?? true) ? .clone : .omit
			case .fromUrl:
				policies[disk.id] = (included?.contains(disk.id) ?? true) ? .reference : .omit
			case .iso:
				policies[disk.id] = .reference   // read-only references always travel
			}
		}
		let guestKind: VMCopyRequest.GuestKind = {
			if case .macOS = config.boot { return .macOS }
			return .generic
		}()
		return VMCopyRequest(
			sourceDir: sourceDir, destinationParent: destinationParent, newName: newName,
			diskPolicies: policies, includedMountIDs: mountIDs.map(Set.init),
			regenerateMAC: regenerateMAC, guestKind: guestKind)
	}

	// MARK: - Configuration

	public func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		let vm = try lookup(name)
		let floors = vm.config.boot.hardwareFloors
		if let cpuCount = cpuCount {
			let clamped = min(max(cpuCount, max(1, floors?.cpu ?? 1)), VMConfig.computeMaxCPUCount())
			try vm.config.setCPUCount(clamped)
		}
		if let memoryBytes = memoryBytes {
			try vm.config.setMemorySize(
				VMConfig.clampMemorySize(size: memoryBytes, floor: floors?.mem ?? 0))
		}
		if let nestedVirtualization {
			// Persist intent; the assembly skips+warns when the host/boot can't honor it.
			vm.config.nestedVirtualization = nestedVirtualization
			try vm.config.saveVMConfig()
		}
		registry.events.emit(.listChanged)
	}

	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.regenerateMACAddress()
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		let vm = try lookup(name)
		let kind = kind ?? MountKind.virtiofs
		try Self.validateMountKind(kind, for: vm.config)
		try vm.config.addMountPoint(HostMountPoint(path: path, tag: tag, kind: kind))
		registry.events.emit(.listChanged)
	}

	// The two kinds the engine knows, and the one boot mode that cannot use the second:
	// macOS guests automount the share and have no scriptable FUSE.
	static func validateMountKind(_ kind: String, for config: VMConfig) throws {
		guard kind == MountKind.virtiofs || kind == MountKind.sshfs else {
			throw MachmanError(
				code: .invalidArgument, message: "Unknown mount kind \u{201C}\(kind)\u{201D}")
		}
		if case .macOS = config.boot, kind == MountKind.sshfs {
			throw MachmanError(
				code: .invalidArgument,
				message: "macOS guests automount the share — sshfs mounts would need macFUSE")
		}
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		let vm = try lookup(name)
		guard let mount = vm.config.mountPoints.first(where: { $0.id.uuidString == mountID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that mount")
		}
		try vm.config.removeMountPoint(mount)
		registry.events.emit(.listChanged)
	}

	public func setMountTag(vm name: String, mountID: String, tag: String)
		async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.setMountTag(id: mountID, tag: tag)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func setMountKind(vm name: String, mountID: String, kind: String)
		async throws -> VMInfo {
		let vm = try lookup(name)
		try Self.validateMountKind(kind, for: vm.config)
		try vm.config.setMountKind(id: mountID, kind: kind)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// MARK: - SSH (1.0.5)

	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.setSSH(
			integrationEnabled: integrationEnabled, reverseApproved: reverseApproved,
			alias: alias)
		registry.events.emit(.sshChanged(vm: name))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// Discovery is host-global (DHCP leases, ARP) and lives in the daemon; the engine half
	// refuses like retire does.
	public func refreshSSH(vm name: String) async throws {
		throw MachmanError(
			code: .invalidState, message: "Only Machman Agent can refresh SSH state")
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.resetSSH()
		registry.events.emit(.sshChanged(vm: name))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func resetSetup(vm name: String) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.resetSetup()
		registry.events.emit(.setupChanged(vm: name))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		let vm = try lookup(name)
		// The persisted choice (only meaningful once installed — fresh guests always
		// serve). ON fills the pre-registered share dirs live; OFF is deferred by
		// design: content, if any, leaves with the run (teardown's removePayload) —
		// never yanked from under a running guest.
		if vm.config.setup != nil, vm.config.setup?.reinstallRequested != serve {
			vm.config.setup?.reinstallRequested = serve
			try vm.config.saveVMConfig()
		}
		if serve, vm.runtime != nil {
			_ = try GuestSetupInstaller.writePayload(for: vm.config)
		}
		registry.events.emit(.setupChanged(vm: name))
		return info(for: vm)
	}

	// MARK: - Operations (1.0.4)

	public func operations() async throws -> [OperationInfo] {
		operationCenter.list()
	}

	public func cancelOperation(id: String) async throws {
		try operationCenter.cancel(id: id)
	}

	public func installRosetta() async throws {
		throw MachmanError(
			code: .invalidState, message: "Only Machman Agent can install Rosetta")
	}

	// MARK: - Run / stop / window

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		// The single choke point (the vmhost serves this same class): an autostarted safe
		// run has nowhere to put its discardable state in v1.
		guard !(policy.autostart && policy.safe) else {
			throw MachmanError(code: .invalidArgument, message: StartPolicy.safeAutostartRefusal)
		}
		let vm = try lookup(name)
		try vm.config.setStartPolicy(policy)
		registry.events.emit(.listChanged)
	}

	public func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
		let vm = try lookup(name)
		try vm.config.setSafety(disks: disks ?? [:], mounts: mounts ?? [:])
		registry.events.emit(.listChanged)
	}

	// MARK: - Serial ports

	public func addConsolePort(vm name: String) async throws {
		try lookup(name).config.addConsolePort()
		registry.events.emit(.listChanged)
	}

	public func removeConsolePort(vm name: String) async throws {
		try lookup(name).config.removeLastConsolePort()
		registry.events.emit(.listChanged)
	}

	public func addUartPort(vm name: String) async throws {
		try lookup(name).config.addUartPort()
		registry.events.emit(.listChanged)
	}

	public func removeUartPort(vm name: String) async throws {
		try lookup(name).config.removeLastUartPort()
		registry.events.emit(.listChanged)
	}

	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		let vm = try lookup(name)
		try vm.config.setSerialLogging(kind: kind, index: index, config: config)
		registry.retuneSerialLogging(vm: vm, kind: kind, index: index, config: config)
		registry.events.emit(.listChanged)
	}

	public func start(vm name: String, options: StartOptions) async throws {
		// Permanent: only the daemon can build shadows. It strips `safe` before forwarding,
		// so a safe flag reaching this engine means a client bypassed the router.
		guard !options.safe else {
			throw MachmanError(
				code: .invalidArgument, message: "This process can’t run safe copies")
		}
		try await registry.start(try lookup(name), openWindow: options.openWindow)
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		try await registry.stop(try lookup(name), mode: mode)
	}

	// Only the daemon ends a vmhost's process; the engine half refuses like retire does.
	public func endProcess(vm name: String) async throws {
		throw MachmanError(
			code: .invalidState, message: "Only Machman Agent can end a VM’s process")
	}

	public func openWindow(vm name: String) async throws {
		try registry.openWindow(try lookup(name))
	}

	public func closeWindow(vm name: String) async throws {
		registry.closeWindow(try lookup(name))
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let vm = try lookup(name)
		guard vm.state.isRunning else { return nil }
		let frame = await registry.captureImage(name: name)
		// Scaled and encoded off the main actor, which drives the VM window and answers the
		// agent: a desktop polling previews cost each running VM a hitch per frame (E68).
		return await Task.detached(priority: .utility) {
			PreviewEncoder.jpeg(from: frame, maxWidth: maxWidth)
		}.value
	}

	// MARK: - macOS install

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		let vm = try lookup(name)
		// Refused up front, before the session reports any phase (MacInstaller guards too).
		guard !vm.config.boot.isMacInstalled else {
			throw MachmanError(
				code: .invalidState, message: "macOS is already installed on \(name)")
		}
		try registry.installSession(for: vm).startInstall(source: source)
	}

	public func cancelMacInstall(vm name: String) async throws {
		registry.installSession(for: try lookup(name)).cancel()
	}

	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		registry.installSession(for: try lookup(name)).phase
	}

	// The vmhost half of vm.safeSave: only the safe-run vmhost may move its own files
	// (single writer). The daemon-side LocalMachman refuses via the nil restrictedName.
	public func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		guard registry.restrictedName == name else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running in safe mode")
		}
		// One instant same-volume rename (a cross-volume save is refused); the card records
		// the save in the operations list. Merged into host.operations by the daemon.
		let opID = operationCenter.begin(
			kind: OperationInfo.Kind.safeSave, vm: name, label: "Saving as \(newName)")
		let vm: VirtualMachine
		do {
			vm = try registry.promoteRestrictedVM(to: newName)
		} catch {
			operationCenter.finish(
				opID, state: OperationInfo.State.failed,
				message: MachmanError.userMessage(for: error))
			throw error
		}
		operationCenter.finish(opID, state: OperationInfo.State.succeeded)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// MARK: - Daemon lifecycle

	public func retire() async throws {
		throw MachmanError(code: .invalidState, message: "This process can’t retire")
	}

	// MARK: - Events

	public func events() async -> AsyncStream<VMEvent> {
		registry.events.stream()
	}

	// MARK: - Mapping

	func lookup(_ name: String) throws -> VirtualMachine {
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		return vm
	}
}

extension LocalMachman: EventLineSource {
	func eventLines() -> AsyncStream<EventLine> {
		registry.events.lineStream()
	}
}
