//
//  Samples+Inspectors.swift
//  MachmanFixtures
//
//  Lane 3c's samples (inspectors, sheets, units): the states the inspectors and the
//  Duplicate sheet show that the base samples don't reach.
//

import Foundation
import MachmanAPI

extension Samples {
	// A Linux guest whose system disk is 500 MB — under one GB, which a whole-GB figure
	// truncated to zero.
	public static func linuxSmallDisk(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.disks[0].sizeBytes = 500 << 20
		return vm
	}

	// A Linux guest at this Mac's memory maximum — where a too-large entry lands (H4).
	public static func linuxMemoryAtMaximum(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.memoryBytes = capabilities.maxMemoryBytes
		return vm
	}

	// A VM whose vmhost never answered, as the daemon serves it: state unknown, marked
	// unresponsive. Not "running", yet the daemon refuses stop-first actions on it.
	public static func neverAnswered(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name, state: .unknown)
		vm.unresponsive = true
		return vm
	}

	// A Linux guest with a second owned storage disk, "data" — a name the system disk can't
	// be renamed to.
	public static func linuxTwoDisks(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.disks.append(DiskInfo(
			id: "storage:data", type: .storage, name: "data",
			path: "\(vmsRoot)/\(name)/data.raw", sizeBytes: 8 << 30, owned: true))
		return vm
	}

	// A Linux (EFI) guest carrying a Mac trackpad, gated the way the daemon gates it: a
	// guest-type limit, not a host one.
	public static func linuxWithTrackpad(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name)
		vm.devices = (vm.devices ?? []) + [DeviceInfo(
			kind: .trackpad,
			unavailable: UnavailabilityInfo(
				reason: .unsupportedHost,
				message: "The Mac trackpad needs a macOS guest \u{2014} it is skipped until "
					+ "macOS is installed."))]
		return vm
	}

	// A kernel-boot guest on a host where uarts are gated (macOS 26.6.1 and later): its uart
	// port carries the engine's gate, worded as VMConfig.uartUnavailability words it.
	public static func kernelBootGatedUART(_ name: String = "Kernel Lab") -> VMInfo {
		var vm = kernelBoot(name)
		let since = SerialPortSupport.privateUARTGatedSinceDisplay
		vm.uartPorts?[0].unavailable = UnavailabilityInfo(
			reason: .privateUARTGated,
			message: "Since macOS \(since), only Apple's own apps can attach UART ports, so VMs "
				+ "start without them.",
			sinceOSVersion: since)
		return vm
	}
}
