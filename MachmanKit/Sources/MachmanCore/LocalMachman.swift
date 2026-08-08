//
//  LocalMachman.swift
//  Machman
//
//  The in-process implementation of MachmanControlling: a straight passthrough from the API
//  seam to VMRegistry, mapping engine types to DTOs. Phase 2 puts the same protocol behind a
//  socket (Machmand serving, RemoteMachman consuming) — clients built against the seam don't
//  change.
//

import Foundation
import AppKit
import Virtualization
import MachmanAPI

@MainActor
public final class LocalMachman: MachmanControlling {
	private let registry: VMRegistry

	public init(registry: VMRegistry) {
		self.registry = registry
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
		return HostCapabilities(
			maxCPUCount: VMConfig.computeMaxCPUCount(),
			minMemoryBytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
			maxMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize,
			freeDiskBytes: freeDiskBytes)
	}

	// MARK: - VM lifecycle

	public func listVMs() async throws -> [VMInfo] {
		registry.list().map { info(for: $0) }
	}

	public func vm(named name: String) async throws -> VMInfo {
		info(for: try lookup(name))
	}

	public func createVM() async throws -> VMInfo {
		info(for: try registry.create())
	}

	public func deleteVM(named name: String) async throws {
		try registry.delete(try lookup(name))
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try registry.rename(try lookup(name), to: newName)
	}

	// MARK: - Configuration

	public func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws {
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
					code: .invalidArgument, message: "storage disk requires name and sizeBytes")
			}
			try vm.config.addNewStorageDisk(name: diskName, size: size)
		case .iso:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "iso disk requires a path")
			}
			try vm.config.addIsoDisk(isoUrl: URL(fileURLWithPath: path))
		case .image:
			guard let path = disk.path, !path.isEmpty else {
				throw MachmanError(code: .invalidArgument, message: "image disk requires a path")
			}
			try vm.config.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: path))))
		}
		registry.events.emit(.listChanged)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		let vm = try lookup(name)
		guard let disk = vm.config.disks.first(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(diskID)' on \(name)")
		}
		try vm.config.deleteDisk(disk: disk)
		registry.events.emit(.listChanged)
	}

	public func addMount(vm name: String, path: String, tag: String) async throws {
		let vm = try lookup(name)
		try vm.config.addMountPoint(HostMountPoint(path: path, tag: tag))
		registry.events.emit(.listChanged)
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		let vm = try lookup(name)
		guard let mount = vm.config.mountPoints.first(where: { $0.id.uuidString == mountID }) else {
			throw MachmanError(code: .notFound, message: "no mount '\(mountID)' on \(name)")
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
				message: "This VM has macOS installed; its boot mode is locked.")
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

	// MARK: - Run / stop / console

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		let vm = try lookup(name)
		try vm.config.setStartPolicy(policy)
		registry.events.emit(.listChanged)
	}

	public func start(vm name: String, options: StartOptions) async throws {
		try await registry.start(try lookup(name), openConsole: options.openConsole)
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		try await registry.stop(try lookup(name), mode: mode)
	}

	public func openConsole(vm name: String) async throws {
		registry.openConsole(try lookup(name))
	}

	public func closeConsole(vm name: String) async throws {
		registry.closeConsole(try lookup(name))
	}

	public func consoleInfo(vm name: String) async throws -> ConsoleInfo {
		let vm = try lookup(name)
		if case .macOS = vm.config.boot {
			return ConsoleInfo(logPath: nil)
		}
		return ConsoleInfo(logPath: vm.config.consoleLogPath())
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let vm = try lookup(name)
		guard vm.state.isRunning else { return nil }
		let image = await registry.captureImage(name: name)
		return Self.jpegData(from: image, maxWidth: maxWidth)
	}

	// MARK: - macOS install

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		try registry.installSession(for: try lookup(name)).startInstall(source: source)
	}

	public func cancelMacInstall(vm name: String) async throws {
		registry.installSession(for: try lookup(name)).cancel()
	}

	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		registry.installSession(for: try lookup(name)).phase
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

	private func info(for vm: VirtualMachine) -> VMInfo {
		let config = vm.config
		let disks = config.disks.map { disk -> DiskInfo in
			switch disk.kind {
			case .storage(let name, _):
				// Server-resolved absolute path: clients must not derive library paths.
				return DiskInfo(
					id: disk.id, type: .storage, name: name,
					path: config.configFilePath(file: "\(name).raw"),
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe)
			case .fromUrl(let url):
				return DiskInfo(
					id: disk.id, type: .image, name: nil, path: url.path,
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe)
			case .iso(let url):
				return DiskInfo(
					id: disk.id, type: .iso, name: nil, path: url.path,
					sizeBytes: config.getDiskSize(disk: disk), safe: disk.safe)
			}
		}
		let mounts = config.mountPoints.map {
			MountInfo(id: $0.id.uuidString, path: $0.path, tag: $0.tag, safe: $0.safe)
		}
		let consoleLogPath: String?
		if case .macOS = config.boot {
			consoleLogPath = nil
		} else {
			consoleLogPath = config.consoleLogPath()
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
			consoleLogPath: consoleLogPath,
			consoleOpen: registry.isConsoleOpen(vm),
			startPolicy: config.startPolicy,
			safeRun: nil,   // daemon-overlay concept: only the router knows a run is safe
			totalRuntimeSeconds: config.totalRuntimeSeconds)
	}

	private func bootInfo(for vm: VirtualMachine) -> BootInfo {
		let config = vm.config
		let kernel = config.kernelSettings.map {
			KernelSettings(
				kernelPath: $0.kernelPath, initrdPath: $0.initialRamdiskPath,
				commandLine: $0.commandLine)
		}
		switch config.boot {
		case .efi:
			return BootInfo(
				mode: .efi, kernel: kernel, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil)
		case .linuxKernel:
			return BootInfo(
				mode: .linuxKernel, kernel: kernel, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil)
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
