//
//  Samples+Tree.swift
//  MachmanFixtures
//
//  The device tree's and the canvas tabs' edge states (wave 3, lane 3e), as the daemon serves
//  them: serial ports that exist but have no socket on a running VM — disabled before the
//  start, enabled after it, or a UART this host can't attach — and a guest with empty
//  sections.
//

import Foundation
import MachmanAPI

extension Samples {
	// Console 0 disabled before the start: configured, not attached, so no socket.
	public static func disabledConsole(
		_ name: String = "Debian", state: VMState = .running
	) -> VMInfo {
		var vm = linux(name, state: state)
		vm.consolePorts?[0].enabled = false
		vm.consolePorts?[0].socketPath = nil
		return vm
	}

	// Console 0 enabled while the VM ran: the running VM has no bridge for it until a restart.
	public static func consoleEnabledAfterStart(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.consolePorts?[0].socketPath = nil
		return vm
	}

	// A UART on a host at or past the private-PL011 gate: the daemon's reason (the text
	// VMDevices.uartUnavailability builds on macOS 26.6.2) and no socket.
	public static func gatedUART(
		_ name: String = "Kernel Lab", state: VMState = .running
	) -> VMInfo {
		var vm = kernelBoot(name, state: state)
		let since = "26.6.1"
		vm.uartPorts?[0].unavailable = UnavailabilityInfo(
			reason: .privateUARTGated,
			message: "UART unavailable: macOS 26.6.2 gates the private PL011 device "
				+ "(com.apple.private.virtualization required, since macOS \(since)); "
				+ "configured uart ports are left unattached.",
			sinceOSVersion: since)
		vm.uartPorts?[0].socketPath = nil
		return vm
	}

	// A Blank-template guest: its system disk and the implied devices, nothing else — no
	// mounts, no serial ports, no Guest Setup (N1's empty sections).
	public static func bareLinux(_ name: String = "Bare") -> VMInfo {
		var vm = linux(name)
		vm.mounts = []
		vm.consolePorts = []
		vm.uartPorts = []
		vm.devices = vm.devices?.filter { $0.kind != .guestSetup }
		vm.setup = nil
		return vm
	}
}
