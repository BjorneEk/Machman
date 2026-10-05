//
//  LocalMachman+VMInfo.swift
//  MachmanCore
//
//  The engine → wire mapping: a VM's config and run state as the VMInfo clients see, with
//  its disks, mounts, serial ports, devices, boot, SSH and guest-setup halves.
//

import Foundation
import Virtualization
import MachmanAPI

extension LocalMachman {
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

	func info(for vm: VirtualMachine) -> VMInfo {
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
				// The rename-stable link once a start has pointed it: no VM name to quote, and
				// a mount made by hand outlives the next rename (C26).
				setupSharePath: GuestSetupInstaller.stableSharePath(for: config)
					?? GuestInstallerWriter.payloadRoot(for: config).path,
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
		case .unknown:
			// A mode a newer Machman wrote (D26): listed, never started or replaced here.
			return BootInfo(
				mode: .unknown, kernel: kernel, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil, ownedKernels: ownedKernels)
		}
	}
}
