//
//  LocalMachman.swift
//  Machman
//
//  The in-process implementation of MachmanControlling: a straight passthrough from the API
//  seam to VMRegistry, mapping engine types to DTOs. Phase 2 puts the same protocol behind a
//  socket (MachmanAgent serving, RemoteMachman consuming) — clients built against the seam don't
//  change.
//

import Foundation
import AppKit
import Virtualization
import MachmanAPI

@MainActor
public final class LocalMachman: MachmanControlling {
	private let registry: VMRegistry
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

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		let vm = try lookup(name)
		switch disk.type {
		case .storage:
			guard let diskName = disk.name, !diskName.isEmpty, let size = disk.sizeBytes else {
				throw MachmanError(
					code: .invalidArgument, message: "A new disk needs a name and a size")
			}
			try vm.config.addNewStorageDisk(name: diskName, size: size)
		case .iso:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "An ISO disk needs a path")
			}
			try vm.config.addIsoDisk(isoUrl: URL(fileURLWithPath: path))
		case .image:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "A disk image needs a path")
			}
			try vm.config.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: path))))
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "Unknown disk type")
		}
		registry.events.emit(.listChanged)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		let vm = try lookup(name)
		guard let disk = vm.config.disks.first(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		try registry.removeDisk(disk, from: vm)
		registry.events.emit(.listChanged)
	}

	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		let vm = try lookup(name)
		let imported = try await copyIntoVM(
			vm, name: name, sourcePath: path, kind: OperationInfo.Kind.importDisk)
		try vm.config.addDisk(disk: imported)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		let vm = try lookup(name)
		guard let disk = vm.config.disks.first(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "\(name) no longer has that disk")
		}
		let vmDir = vm.config.vmDirPath()
		let sourcePath: String
		switch disk.kind {
		case .storage:
			throw MachmanError(
				code: .invalidState, message: "This disk is already owned by the VM")
		case .iso(let url):
			guard !url.path.hasPrefix(vmDir + "/") else {
				throw MachmanError(
					code: .invalidState, message: "This disk is already owned by the VM")
			}
			sourcePath = url.path
		case .fromUrl(let url):
			sourcePath = url.path
		}
		let promoted = try await copyIntoVM(
			vm, name: name, sourcePath: sourcePath, kind: OperationInfo.Kind.promoteDisk)
		try vm.config.replaceDisk(id: diskID, kind: promoted.kind)   // the flags carry
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The shared import mechanics: gather taken names on-actor, then detach the sniff+copy
	// (external images can be real cross-volume byte copies). Progress reuses copyProgress
	// AND registers an operation (dual-emitted for older clients).
	private func copyIntoVM(
		_ vm: VirtualMachine, name: String, sourcePath: String, kind: String
	) async throws -> VMDisk {
		let vmDir = vm.config.vmDirPath()
		let taken = Set(vm.config.disks.compactMap { disk -> String? in
			if case .storage(let storageName, _) = disk.kind { return storageName }
			return nil
		})
		let events = registry.events
		let center = operationCenter
		let cancelFlag = CancelFlag()
		let file = (sourcePath as NSString).lastPathComponent
		let verb = kind == OperationInfo.Kind.promoteDisk ? "Promoting" : "Importing"
		let opID = center.begin(
			kind: kind, vm: name, label: "\(verb) \(file)", cancel: { cancelFlag.set() })
		do {
			let disk = try await Task.detached(priority: .userInitiated) {
				try DiskImport.importFile(
					src: sourcePath, vmDir: vmDir, takenStorageNames: taken,
					progress: { copied, total in
						Task { @MainActor in
							events.emit(.copyProgress(
								vm: name, copiedBytes: copied, totalBytes: total))
							center.update(
								opID,
								fraction: total > 0 ? Double(copied) / Double(total) : nil,
								completedBytes: Int64(copied), totalBytes: Int64(total))
						}
					},
					isCancelled: { cancelFlag.get() })
			}.value
			center.finish(opID, state: OperationInfo.State.succeeded)
			return disk
		} catch {
			center.finish(
				opID,
				state: cancelFlag.get()
					? OperationInfo.State.cancelled : OperationInfo.State.failed,
				message: MachmanError.userMessage(for: error))
			throw error
		}
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

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		let vm = try lookup(name)
		try vm.config.updateKernelSettings(LinuxKernelBoot(
			kernelPath: settings.kernelPath,
			initialRamdiskPath: settings.initrdPath,
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

	public func renameDisk(vm name: String, diskID: String, newName: String)
		async throws -> VMInfo {
		let vm = try lookup(name)
		guard !vm.state.isRunning else {
			throw MachmanError(
				code: .invalidState, message: "Stop \(name) before renaming its disks")
		}
		try registry.renameStorageDisk(id: diskID, of: vm, to: newName)
		registry.events.emit(.listChanged)
		return info(for: vm)
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

	// MARK: - Guest devices (1.0.4)

	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		let vm = try lookup(name)
		try attachDevice(kind, to: vm)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The sync core, so the ordering is testable without the async shell. The two
	// pre-1.0.7 installer kinds map onto guestSetup, so clients that still ask for them
	// get the unified installer rather than a refusal.
	func attachDevice(_ kind: DeviceKind, to vm: VirtualMachine) throws {
		var kind = kind
		if kind == .sshInstaller || kind == .consoleLoginInstaller {
			kind = .guestSetup
		}
		try Self.validateDeviceKind(kind, for: vm.config)
		try vm.config.addDevice(GuestDevice(kind: kind))
		// Payloads are ephemeral (1.0.7): they exist while the VM runs and appear at the
		// next assembly otherwise. The one eager write left is attach-on-a-RUNNING VM — a
		// guest without a virtiofs driver reaches the payload by mounting the directory
		// over SSH from a live guest, and finding it empty is a dead end with no
		// explanation. Runs in the process that owns the config (the vmhost proxies this
		// call while hosted), so the single-writer rule holds.
		if kind == .guestSetup, vm.state.isRunning {
			try? GuestSetupInstaller.writePayload(for: vm.config)
		}
	}

	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		guard kind != .unknown else {
			throw MachmanError(code: .invalidArgument, message: "Unknown device kind")
		}
		var kind = kind
		if kind == .sshInstaller || kind == .consoleLoginInstaller {
			kind = .guestSetup
		}
		let vm = try lookup(name)
		try detachDevice(kind, from: vm)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The sync core (attachDevice's twin), so the ordering is testable without the async
	// shell. Guest setup's share dirs stop being served at the next boot and leave the disk
	// with the device — at once when stopped, at teardown when running (D12: like
	// vm.setup.serve off, content is never yanked from under a running guest; teardown's
	// removePayload runs after the final report poll). The keypair and config.ssh survive
	// re-adds — vm.ssh.reset is the deeper wipe.
	func detachDevice(_ kind: DeviceKind, from vm: VirtualMachine) throws {
		try vm.config.removeDevice(kind: kind)
		if kind == .guestSetup, vm.runtime == nil {
			GuestSetupInstaller.removePayload(for: vm.config)
		}
	}

	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		let vm = try lookup(name)
		try Self.validateDeviceSettings(device)
		guard let stored = vm.config.devices.first(where: { $0.deviceKind == device.kind })
		else {
			throw MachmanError(
				code: .notFound, message: "\(name) has no \(device.kind.displayLabel) device")
		}
		try vm.config.updateDevice(Self.guestDevice(from: device, replacing: stored))
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	// The wire → config half of vm.device.update: every setting is taken from the request,
	// except a .unknown capture mode — an older client echoing back a newer daemon's mode it
	// could not read — which keeps what is stored rather than letting the echo erase it.
	nonisolated static func guestDevice(from device: DeviceInfo, replacing stored: GuestDevice)
		-> GuestDevice {
		var updated = GuestDevice(kind: device.kind)
		updated.enabled = device.enabled
		updated.displayWidthPixels = device.displayWidthPixels
		updated.displayHeightPixels = device.displayHeightPixels
		updated.displayPixelsPerInch = device.displayPixelsPerInch
		updated.systemKeyCapture = device.systemKeyCapture == .unknown
			? stored.systemKeyCapture : device.systemKeyCapture?.rawValue
		updated.sharesClipboard = device.sharesClipboard
		return updated
	}

	// The config → wire half of a device, the inverse of guestDevice(from:replacing:): the
	// capture mode is served exactly as stored, so a newer daemon's mode goes out in its own
	// spelling (never "unknown") and a client's echo brings it back unchanged.
	static func deviceInfo(from device: GuestDevice, macGuest: Bool) -> DeviceInfo {
		var info = DeviceInfo(
			kind: device.deviceKind, enabled: device.enabled,
			displayWidthPixels: device.displayWidthPixels,
			displayHeightPixels: device.displayHeightPixels,
			displayPixelsPerInch: device.displayPixelsPerInch,
			sharesClipboard: device.sharesClipboard,
			unavailable: deviceUnavailability(device.deviceKind, macGuest: macGuest))
		info.systemKeyCaptureSpelling = device.systemKeyCapture
		return info
	}

	// Add-time validation keeps impossible configs out of the start path (which would only
	// fail later inside VZ validate() with a far worse message).
	static func validateDeviceKind(_ kind: DeviceKind, for config: VMConfig) throws {
		let macGuest: Bool = { if case .macOS = config.boot { return true }; return false }()
		switch kind {
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "Unknown device kind")
		case .trackpad where !macGuest:
			throw MachmanError(
				code: .invalidArgument,
				message: "The Mac trackpad needs a macOS guest — install macOS first")
		case .consoleLoginInstaller:
			throw MachmanError(
				code: .invalidArgument, message: "Replaced by Guest Setup in Machman 1.0.7")
		case .sshInstaller:
			throw MachmanError(
				code: .invalidArgument, message: "Replaced by Guest Setup in Machman 1.0.7")
		case .clipboard where macGuest, .rosetta where macGuest:
			throw MachmanError(
				code: .invalidArgument,
				message: "\(kind.displayLabel) isn’t supported for macOS guests")
		default:
			break
		}
	}

	private static func validateDeviceSettings(_ device: DeviceInfo) throws {
		guard device.kind != .unknown else {
			throw MachmanError(code: .invalidArgument, message: "Unknown device kind")
		}
		for value in [device.displayWidthPixels, device.displayHeightPixels] {
			if let value, !(640...8192).contains(value) {
				throw MachmanError(
					code: .invalidArgument,
					message: "Display size must be between 640 and 8192 pixels")
			}
		}
		if let ppi = device.displayPixelsPerInch, !(40...300).contains(ppi) {
			throw MachmanError(
				code: .invalidArgument, message: "Pixels per inch must be between 40 and 300")
		}
	}

	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?, devices: [String: Bool]?
	) async throws {
		let vm = try lookup(name)
		try vm.config.setEnabled(
			disks: disks ?? [:], mounts: mounts ?? [:],
			console: console ?? [:], uart: uart ?? [:], devices: devices ?? [:])
		registry.events.emit(.listChanged)
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
			code: .invalidState, message: "only the daemon can refresh SSH state")
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

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		let vm = try lookup(name)
		try vm.config.setKernelOverride(
			forFileAt: path, commandLine: commandLine, enabled: overrideEnabled)
		registry.events.emit(.listChanged)
		return info(for: vm)
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		let vm = try lookup(name)
		try vm.config.growStorageDisk(id: diskID, to: sizeBytes)
		registry.events.emit(.listChanged)
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
			throw MachmanError(
				code: .invalidArgument, message: "A safe run can’t start automatically")
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

	public func openWindow(vm name: String) async throws {
		try registry.openWindow(try lookup(name))
	}

	public func closeWindow(vm name: String) async throws {
		registry.closeWindow(try lookup(name))
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let vm = try lookup(name)
		guard vm.state.isRunning else { return nil }
		let image = await registry.captureImage(name: name)
		return Self.jpegData(from: image, maxWidth: maxWidth)
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

	private func lookup(_ name: String) throws -> VirtualMachine {
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		return vm
	}

	// The served mounts. automounted comes from the guest's setup report: the ONE share
	// automount covers every virtiofs mount (they are its tag subdirectories, so the
	// guest directory is the share's path + tag); sshfs mounts match their own record by
	// tag and land at its reported path. Internal static seam — tests reach the matching
	// rules without the async surface (VMTestDir redirects are sync-only by design).
	static func mountInfos(for config: VMConfig) -> [MountInfo] {
		let automounts = config.setup?.automounts ?? []
		let shareAutomount = automounts.first { $0.kind == MountKind.virtiofs }
		return config.mountPoints.map { mount in
			let automountedAt: String?
			if mount.kind == MountKind.sshfs {
				automountedAt = automounts.first {
					$0.kind == MountKind.sshfs && $0.target == mount.tag
				}?.path
			} else {
				automountedAt = shareAutomount.map { $0.path + "/" + mount.tag }
			}
			return MountInfo(
				id: mount.id.uuidString, path: mount.path, tag: mount.tag, safe: mount.safe,
				enabled: mount.enabled ? nil : false,
				kind: mount.kind == MountKind.virtiofs ? nil : mount.kind,
				automounted: automountedAt != nil ? true : nil,
				automountedAt: automountedAt)
		}
	}

	private func info(for vm: VirtualMachine) -> VMInfo {
		let config = vm.config
		// enabled rides tri-state: nil = enabled (the wire's old-daemon meaning), false pins.
		func enabledFlag(_ enabled: Bool) -> Bool? { enabled ? nil : false }
		let disks = config.disks.map { disk -> DiskInfo in
			switch disk.kind {
			case .storage(let name, _):
				// Server-resolved absolute path: clients must not derive library paths.
				return DiskInfo(
					id: disk.id, type: .storage, name: name,
					path: config.configFilePath(file: "\(name).raw"),
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe,
					owned: true, enabled: enabledFlag(disk.enabled))
			case .fromUrl(let url):
				return DiskInfo(
					id: disk.id, type: .image, name: nil, path: url.path,
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe,
					owned: false, enabled: enabledFlag(disk.enabled))
			case .iso(let url):
				return DiskInfo(
					id: disk.id, type: .iso, name: nil, path: url.path,
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe,
					owned: url.path.hasPrefix(config.vmDirPath() + "/"),
					enabled: enabledFlag(disk.enabled))
			}
		}
		let mounts = Self.mountInfos(for: config)
		let macGuest: Bool = { if case .macOS = config.boot { return true }; return false }()
		func serialPorts(_ kind: SerialPortKind, _ ports: [SerialPort]) -> [SerialPortInfo] {
			let uartIssue = kind == .uart ? VMConfig.uartUnavailability() : nil
			// Guest names number the ENABLED ports compactly (that's what the guest sees at
			// the next boot); a disabled port keeps its config-position name for identity.
			var enabledSeen = 0
			return ports.enumerated().map { index, port in
				let guestIndex: Int
				if port.enabled {
					guestIndex = enabledSeen
					enabledSeen += 1
				} else {
					guestIndex = index
				}
				return SerialPortInfo(
					kind: kind, index: index,
					guestDevice: kind.guestDevice(index: guestIndex, macGuest: macGuest),
					logging: port.logging,
					socketPath: registry.serialSocketPath(vm: vm, kind: kind, index: index),
					logPath: registry.serialLogPath(vm: vm, kind: kind, index: index),
					mmioBase: nil, irq: nil,   // uart mmio/irq: filled once platform info exists
					unavailable: uartIssue,
					enabled: enabledFlag(port.enabled),
					guestIndex: guestIndex,
					guestName: port.guestName)
			}
		}
		// Persisted SSH half plus the paths and names clients must not derive themselves;
		// address and reachability stay nil here (daemon overlay, like safeRun).
		//
		// Served as soon as the installer is ATTACHED, not only once a guest has reported:
		// the host facts (this Mac's account, the folder a driverless guest mounts) are
		// what the setup guide has to show BEFORE the first run, and deriving them
		// client-side is exactly the drift this shape exists to prevent.
		let sshAttached = config.devices.contains {
			$0.deviceKind == .guestSetup && $0.enabled
		}
		let ssh: SSHInfo? = config.servedSSHState(installerAttached: sshAttached).map { state in
			let keyPath = config.configFilePath(file: "ssh/id_ed25519")
			let hasKey = FileManager.default.fileExists(atPath: keyPath)
			// Served only once the pin FILE exists: clients turn strict host-key checking
			// on when they get this path, and a path to a file that is not there yet
			// would lock every session out instead of falling back to accept-new.
			let pinPath = SSHSetupInstaller.knownHostsPath(for: config)
			let hasPin = FileManager.default.fileExists(atPath: pinPath)
			return SSHInfo(
				configured: true,
				guestUser: state.guestUser,
				guestHostname: state.guestHostname,
				guestOS: state.guestOS,
				guestOSVersion: state.guestOSVersion,
				guestHostKey: state.guestHostKey,
				reverseState: state.reverseStateValue,
				reversePublicKey: state.reversePublicKey,
				integrationEnabled: state.integrationEnabled,
				lastReportAt: state.lastReportAt,
				lastRunStatus: state.lastRunStatus,
				lastRunNote: state.lastRunNote,
				lastTransport: state.lastTransport,
				scriptVersion: state.scriptVersion,
				sshfsAvailable: state.sshfsAvailable,
				sshfsMountReady: state.sshfsMountReady,
				sshfsMountRoot: state.sshfsMountRoot,
				alias: config.effectiveSSHAlias,
				identityFilePath: hasKey ? keyPath : nil,
				knownHostsPath: hasPin ? pinPath : nil,
				setupSharePath: GuestInstallerWriter.payloadRoot(for: config).path,
				hostUser: NSUserName(),
				// The gateway from the last address the guest reported, so the BSD setup
				// guide has a real target even while the VM is stopped. The daemon
				// overwrites this with the live one when discovery has an answer.
				hostAddressForGuest: state.lastAddress
					.flatMap { SSHDiscovery.hostAddress(seenFrom: $0) })
		}
		// The guest-setup half (1.0.7): the persisted report snapshot, plus the one
		// server-resolved field — the script version this app ships, so clients can say
		// "an update is available" without a second source of truth.
		let setup: GuestSetupInfo? = (config.setup
			?? (sshAttached ? GuestSetupConfig() : nil)).map { state in
			GuestSetupInfo(
				installed: state.installed,
				guestOS: state.guestOS,
				guestOSFamily: state.guestOSFamily,
				guestOSVersion: state.guestOSVersion,
				guestInit: state.guestInit,
				lastReportAt: state.lastReportAt,
				scriptVersion: state.scriptVersion,
				currentScriptVersion: GuestSetupInstaller.scriptVersion,
				lastRunStatus: state.lastRunStatus,
				lastRunNote: state.lastRunNote,
				lastTransport: state.lastTransport,
				errors: state.errors.isEmpty ? nil : state.errors,
				notes: state.notes.isEmpty ? nil : state.notes,
				features: state.features.isEmpty ? nil : state.features,
				consoles: state.consoles.isEmpty ? nil : state.consoles,
				automounts: state.automounts.isEmpty ? nil : state.automounts,
				reinstallRequested: state.reinstallRequested)
		}
		// Unknown kinds (written by a NEWER daemon) are preserved in config but not served:
		// this engine can't edit them, and an older client would still collide them on
		// DeviceInfo's kind-derived id (A7 keeps the spelling only from this build on).
		let devices = config.devices.compactMap { device -> DeviceInfo? in
			guard device.deviceKind != .unknown else { return nil }
			return Self.deviceInfo(from: device, macGuest: macGuest)
		}
		return VMInfo(
			name: config.name,
			state: vm.state,
			created: config.created,
			lastRan: config.lastRan,
			cpuCount: config.cpuCount,
			memoryBytes: config.memorySize,
			macAddress: config.macAddress,
			disks: disks,
			mounts: mounts,
			boot: bootInfo(for: vm),
			windowOpen: registry.isWindowOpen(vm),
			startPolicy: config.startPolicy,
			safeRun: nil,   // daemon-overlay concept: only the router knows a run is safe
			totalRuntimeSeconds: config.totalRuntimeSeconds,
			consolePorts: serialPorts(.console, config.consolePorts),
			uartPorts: serialPorts(.uart, config.uartPorts),
			devices: devices,
			nestedVirtualization: config.nestedVirtualization,
			ssh: ssh, setup: setup)
	}

	// Why a configured device cannot attach here — the serial-unavailability pattern for
	// devices. Single source with resolvedDevices()' skip logic.
	private static func deviceUnavailability(
		_ kind: DeviceKind, macGuest: Bool
	) -> UnavailabilityInfo? {
		switch kind {
		case .trackpad where !macGuest:
			return UnavailabilityInfo(
				reason: .unsupportedHost,
				message: "The Mac trackpad needs a macOS guest — it is skipped until "
					+ "macOS is installed.")
		case .consoleLoginInstaller where !macGuest:
			return UnavailabilityInfo(
				reason: .unsupportedHost,
				message: "The console login installer needs a macOS guest — it is skipped until "
					+ "macOS is installed.")
		case .clipboard where macGuest:
			return UnavailabilityInfo(
				reason: .unsupportedHost,
				message: "Clipboard sharing (spice agent) is not supported for macOS guests.")
		case .rosetta where macGuest:
			return UnavailabilityInfo(
				reason: .unsupportedHost,
				message: "Rosetta is not supported for macOS guests.")
		case .rosetta where VZLinuxRosettaDirectoryShare.availability != .installed:
			return UnavailabilityInfo(
				reason: .notInstalled,
				message: "Rosetta is not installed on this host — install it to run "
					+ "x86-64 binaries in Linux guests.")
		default:
			return nil
		}
	}

	private func bootInfo(for vm: VirtualMachine) -> BootInfo {
		let config = vm.config
		let kernel = config.kernelSettings.map {
			KernelSettings(
				kernelPath: $0.kernelPath, initrdPath: $0.initialRamdiskPath,
				commandLine: $0.commandLine)
		}
		let owned = config.ownedKernelFiles().map { file -> OwnedKernelFile in
			var file = file
			if let override = config.kernelOverrides[VMConfig.kernelOverrideKey(for: file)] {
				file.overrideCommandLine = override.commandLine
				file.overrideEnabled = override.enabled
			}
			return file
		}
		let ownedKernels = owned.isEmpty ? nil : owned   // nil-omitted keeps the wire fixture stable
		switch config.boot {
		case .efi:
			return BootInfo(
				mode: .efi, kernel: kernel, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil, ownedKernels: ownedKernels)
		case .linuxKernel:
			return BootInfo(
				mode: .linuxKernel, kernel: kernel, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil, ownedKernels: ownedKernels)
		case .macOS(let m):
			// MachmanAPI.MacInstallState is the DTO; the unqualified name is the persisted enum.
			let state: MachmanAPI.MacInstallState
			switch m.installState {
			case .installed:
				state = MachmanAPI.MacInstallState(kind: .installed)
			case .failed(let msg):
				state = MachmanAPI.MacInstallState(kind: .failed, message: msg)
			case .installing:
				state = MachmanAPI.MacInstallState(
					kind: registry.isInstalling(vm) ? .installing : .interrupted)
			}
			return BootInfo(
				mode: .macOS, kernel: kernel, macInstallState: state,
				minCPUCount: m.minimumCPUCount, minMemoryBytes: m.minimumMemorySize)
		}
	}

	nonisolated private static func jpegData(from image: NSImage, maxWidth: Int?) -> Data? {
		var source = image
		if let maxWidth = maxWidth, image.size.width > CGFloat(maxWidth), image.size.width > 0 {
			let scale = CGFloat(maxWidth) / image.size.width
			let newSize = NSSize(
				width: CGFloat(maxWidth), height: (image.size.height * scale).rounded())
			let scaled = NSImage(size: newSize)
			scaled.lockFocus()
			image.draw(
				in: NSRect(origin: .zero, size: newSize),
				from: NSRect(origin: .zero, size: image.size),
				operation: .copy, fraction: 1.0)
			scaled.unlockFocus()
			source = scaled
		}
		guard let tiff = source.tiffRepresentation,
			let rep = NSBitmapImageRep(data: tiff) else {
			return nil
		}
		return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
	}
}

extension LocalMachman: EventLineSource {
	func eventLines() -> AsyncStream<EventLine> {
		registry.events.lineStream()
	}
}
