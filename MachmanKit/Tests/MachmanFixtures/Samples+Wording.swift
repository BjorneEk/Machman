//
//  Samples+Wording.swift
//  MachmanFixtures
//
//  Lane 4a's samples (inspector and guide text): the mount cases the mount guide covers, a
//  kernel-boot console the guest hasn't named, consoles whose login states it reported and a
//  one-core VM.
//

import Foundation
import MachmanAPI

extension Samples {
	public static let srcMountID = "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"

	// The library's Linux guest with its source mount not automounted (no setup report
	// automount yet), so the guest path is where the offered commands put it.
	public static func linuxManualMount(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.mounts = vm.mounts.map { mount in
			var mount = mount
			mount.automounted = nil
			mount.automountedAt = nil
			return mount
		}
		return vm
	}

	// A macOS guest sharing the same source folder (it automounts in the guest).
	public static func macOSWithMount(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOS(name)
		vm.mounts = [MountInfo(id: srcMountID, path: "/Users/demo/src", tag: "src")]
		return vm
	}

	// A Linux guest with four consoles whose login states the setup report carries: the
	// kernel console with systemd's own login, one set up for the next boot (and the kernel
	// console there next), one without a login and one the guest doesn't have.
	public static func linuxConsolesReported(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name)
		vm.consolePorts = (0..<4).map { index in
			SerialPortInfo(
				kind: .console, index: index,
				guestDevice: SerialPortKind.console.guestDevice(index: index, os: .linux),
				logging: SerialLogConfig(), guestIndex: index, guestName: "hvc\(index)")
		}
		vm.setup?.consoles = [
			GuestConsoleInfo(
				device: "hvc0", login: GuestConsoleLogin.activeAuto, kernelConsole: true),
			GuestConsoleInfo(
				device: "hvc1", login: GuestConsoleLogin.configured, kernelConsolePending: true),
			GuestConsoleInfo(device: "hvc2", login: GuestConsoleLogin.none),
			GuestConsoleInfo(device: "hvc3", login: GuestConsoleLogin.missing),
		]
		return vm
	}

	// A Linux guest with a single core (the CPU row's count).
	public static func linuxOneCore(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.cpuCount = 1
		return vm
	}

	// A kernel-boot guest whose console the guest hasn't reported yet, so the inspector shows
	// the Linux device row and the kernel command-line hint.
	public static func kernelBootConsoleUnreported(_ name: String = "Kernel Lab") -> VMInfo {
		var vm = kernelBoot(name)
		vm.consolePorts?[0].guestName = nil
		return vm
	}
}
