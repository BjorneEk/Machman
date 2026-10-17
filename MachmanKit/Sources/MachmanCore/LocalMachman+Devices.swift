//
//  LocalMachman+Devices.swift
//  MachmanCore
//
//  Guest devices (vm.device.*): add, remove and update, with the add-time checks that keep a
//  config VZ would refuse out of the start path, and vm.setEnabled.
//

import Foundation
import MachmanAPI

extension LocalMachman {
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
}
