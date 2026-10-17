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

	// A Linux guest whose config a newer Machman wrote a boot mode into (C11): the daemon
	// serves the mode as unknown and keeps the VM from starting.
	public static func newerBootMode(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.boot = BootInfo(
			mode: .unknown, kernel: nil, macInstallState: nil, minCPUCount: nil,
			minMemoryBytes: nil)
		return vm
	}

	// An unfinished Mac (its install failed) that Machman Agent hasn't reached since a
	// restart (P37): state unknown, so Install macOS… waits instead of offering itself.
	public static func macOSUnfinishedUnreached(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOSFailedInstallReadable(name)
		vm.state = .unknown
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

	// A Linux guest before a switch to macOS (D32): a roomy owned system disk, the small
	// "data" disk, a referenced image and its installer ISO — every row the switch sheet offers
	// or leaves out.
	public static func linuxBeforeMacSwitch(_ name: String = "Alpine") -> VMInfo {
		var vm = linuxTwoDisks(name)
		vm.disks[0].sizeBytes = 80 << 30
		let image = "/Users/demo/VM Images/ubuntu-24.04-arm64.img"
		vm.disks.append(DiskInfo(
			id: "url:" + URL(fileURLWithPath: image).absoluteString, type: .image, name: nil,
			path: image, sizeBytes: 20 << 30, owned: false))
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
			message: "Since macOS \(since), only Apple’s own apps can attach UART ports, so VMs "
				+ "start without them.",
			sinceOSVersion: since)
		return vm
	}

	// An installed macOS guest with one uart port (its PL011 is the kernel debug UART).
	public static func macOSWithUART(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOS(name)
		vm.uartPorts = [
			SerialPortInfo(
				kind: .uart, index: 0,
				guestDevice: SerialPortKind.uart.guestDevice(index: 0, os: .macOS),
				logging: SerialLogConfig()),
		]
		return vm
	}

	// A running Linux guest whose console logs to a file: the daemon serves the log's path
	// (VMConfig.serialLogURL's naming) only while the VM runs with logging on.
	public static func linuxConsoleLog(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.consolePorts?[0].logPath = "\(vmsRoot)/\(name)/serial-console0.log"
		return vm
	}

	// A well-formed ed25519 public-key line (fixed bytes), as a guest reports its reverse
	// key: the inspector shows its SHA256 fingerprint.
	public static let reverseKeyLine: String = {
		var blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
		blob += Data((0..<32).map { UInt8(($0 * 37 + 11) % 256) })
		return "ssh-ed25519 \(blob.base64EncodedString()) demo@debian"
	}()

	// A Linux guest whose reverse (guest → Mac) key is in `state`. The daemon keeps serving
	// the key after a denial, so a later approval can still show it.
	public static func linuxReverse(
		_ state: SSHInfo.ReverseState, _ name: String = "Debian"
	) -> VMInfo {
		var vm = linux(name)
		vm.ssh?.reverseState = state
		vm.ssh?.reversePublicKey = reverseKeyLine
		return vm
	}

	// A kernel-boot guest whose share automounts (the report's "virtiofs host-share
	// /mnt/machman/share" line), set to serve the installer again.
	public static func kernelBootReinstall(_ name: String = "Kernel Lab") -> VMInfo {
		var vm = kernelBoot(name)
		vm.setup?.reinstallRequested = true
		vm.setup?.automounts = [
			GuestAutomountInfo(
				kind: MountKind.virtiofs, target: GuestPaths.shareTag, path: GuestPaths.share),
		]
		return vm
	}

	// A Linux (EFI) guest whose reverse key is approved and that has booted once, so the
	// guide's BSD bootstrap can fill in this Mac's address and the real share path.
	public static func linuxReverseApproved(_ name: String = "Debian") -> VMInfo {
		var vm = linuxReverse(.approved, name)
		vm.setup?.automounts = []
		vm.ssh?.hostUser = "demo"
		vm.ssh?.hostAddressForGuest = "192.168.64.1"
		vm.ssh?.setupSharePath = "\(vmsRoot)/.machman-shares/machman-3f2a9c1d7e4b"
		return vm
	}

	// A Linux guest whose disks have long labels: an image referenced from deep in iCloud
	// Drive (labelled by its last two path components) and a long-named owned disk.
	public static func linuxLongDiskNames(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name)
		let image = "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/VM Images/"
			+ "ubuntu-24.04.2-live-server-arm64-with-build-tools.img"
		let scratch = "scratch-space-for-nightly-build-artifacts-and-their-caches"
		vm.disks += [
			DiskInfo(
				id: "url:" + URL(fileURLWithPath: image).absoluteString, type: .image,
				name: nil, path: image, sizeBytes: 20 << 30, owned: false),
			DiskInfo(
				id: "storage:\(scratch)", type: .storage, name: scratch,
				path: "\(vmsRoot)/\(name)/\(scratch).raw", sizeBytes: 64 << 30, owned: true),
		]
		return vm
	}

	// A macOS guest whose install failed, with the engine's own reason: the whole error's
	// description (MacInstaller stores "\(error)"), as long as VZ's run. Spelled out: an
	// NSError's description lists its userInfo in a different order from run to run (Q16).
	public static func macOSFailedInstall(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOS(name)
		let message = "Error Domain=VZErrorDomain Code=10007 \"Installation failed.\" "
			+ "UserInfo={NSLocalizedDescription=Installation failed., "
			+ "NSLocalizedFailureReason=A software update is required to complete the "
			+ "installation.}"
		vm.boot.macInstallState = MacInstallState(kind: .failed, message: message)
		return vm
	}
}
