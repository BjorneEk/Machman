//
//  Samples.swift
//  MachmanFixtures
//
//  Sample VMs built only from MachmanAPI DTOs, shaped like what the daemon serves: disk ids
//  follow VMDisk.id ("storage:<name>", "iso:<url>", "url:<url>"), storage paths are
//  server-resolved inside the VM directory, device sets are ImpliedDevices', and serial
//  ports are named by SerialPortKind.guestDevice. Dates are fixed so renders are stable.
//  Tests and render scenes both start here; a lane that needs a new state (a new DTO field)
//  adds a builder here rather than inventing one inline.
//

import Foundation
import MachmanAPI

public enum Samples {
	public static let epoch = Date(timeIntervalSince1970: 1_780_000_000)
	public static let vmsRoot = "/Users/demo/Library/Application Support/"
		+ "com.gustaffranzen.Machman/VMs"
	// Console sockets of running samples: under /var/empty (root-owned, read-only, empty), so
	// no process can ever create one there and a terminal that connects fails with ENOENT.
	public static let sockets = "/var/empty/machman-sample"

	public static let capabilities = HostCapabilities(
		maxCPUCount: 10, minMemoryBytes: 512 << 20, maxMemoryBytes: 24 << 30,
		freeDiskBytes: 412 << 30, nestedVirtualizationSupported: true,
		rosettaAvailability: RosettaAvailability.installed,
		hostDisplayWidthPixels: 3024, hostDisplayHeightPixels: 1964, maxSerialPorts: 8)

	// A Linux EFI guest: owned system disk, an installer ISO by reference, one virtiofs
	// mount, one console port, the implied non-mac device set, guest setup installed.
	public static func linux(
		_ name: String = "Debian", state: VMState = .stopped
	) -> VMInfo {
		let running = state.isRunning
		return VMInfo(
			name: name, state: state, created: epoch, lastRan: epoch.addingTimeInterval(86_400),
			cpuCount: 4, memoryBytes: 4 << 30, macAddress: "5e:2c:7a:10:44:01",
			disks: [
				DiskInfo(
					id: "storage:system", type: .storage, name: "system",
					path: "\(vmsRoot)/\(name)/system.raw", sizeBytes: 32 << 30, owned: true),
				DiskInfo(
					id: "iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso",
					type: .iso, name: nil,
					path: "/Users/demo/Downloads/debian-13-arm64-netinst.iso",
					sizeBytes: 754 << 20, safe: false, owned: false),
			],
			mounts: [
				MountInfo(
					id: "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11", path: "/Users/demo/src",
					tag: "src", kind: MountKind.virtiofs, automounted: true,
					automountedAt: "/mnt/machman/src"),
			],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			windowOpen: running, startPolicy: StartPolicy(),
			totalRuntimeSeconds: 7_260,
			consolePorts: [
				SerialPortInfo(
					kind: .console, index: 0,
					guestDevice: SerialPortKind.console.guestDevice(index: 0, os: .linux),
					logging: SerialLogConfig(),
					socketPath: running ? "\(sockets)/\(name)-console0.sock" : nil,
					guestIndex: 0, guestName: "hvc0"),
			],
			uartPorts: [],
			devices: ImpliedDevices.kinds(macGuest: false).map { DeviceInfo(kind: $0) }
				+ [DeviceInfo(kind: .guestSetup)],
			ssh: SSHInfo(
				configured: true, guestUser: "demo", guestHostname: name.lowercased(),
				guestOS: "debian", guestOSVersion: "13", reverseState: .none,
				integrationEnabled: true, lastReportAt: epoch, lastRunStatus: "ok",
				alias: "\(name.lowercased()).machman", hostUser: "demo",
				address: running ? "192.168.64.7" : nil, addressSource: running ? "dhcp" : nil,
				reachability: running ? .ready : nil),
			setup: GuestSetupInfo(
				installed: true, guestOS: "debian", guestOSFamily: "debian",
				guestOSVersion: "13", guestInit: "systemd", lastReportAt: epoch,
				scriptVersion: 3, currentScriptVersion: 3, lastRunStatus: "ok"))
	}

	// A macOS guest: installed, the mac device set (trackpad included), macOS floors.
	public static func macOS(
		_ name: String = "Sequoia", state: VMState = .stopped
	) -> VMInfo {
		VMInfo(
			name: name, state: state, created: epoch, lastRan: nil,
			cpuCount: 4, memoryBytes: 8 << 30, macAddress: "5e:2c:7a:10:44:02",
			disks: [
				DiskInfo(
					id: "storage:system", type: .storage, name: "system",
					path: "\(vmsRoot)/\(name)/system.raw", sizeBytes: 80 << 30, owned: true),
			],
			mounts: [],
			boot: BootInfo(
				mode: .macOS, kernel: nil,
				macInstallState: MacInstallState(kind: .installed),
				minCPUCount: 2, minMemoryBytes: 4 << 30),
			windowOpen: state.isRunning, startPolicy: StartPolicy(),
			consolePorts: [], uartPorts: [],
			devices: ImpliedDevices.kinds(macGuest: true).map { kind in
				kind == .graphics
					? DeviceInfo(
						kind: kind, displayWidthPixels: 1920, displayHeightPixels: 1200,
						displayPixelsPerInch: 144)
					: DeviceInfo(kind: kind)
			})
	}

	// A direct-kernel-boot guest: two owned kernels (one active, with an override) and an
	// initramfs, a console and a uart port, plus the opt-in entropy and Rosetta devices so
	// every device inspector has a sample.
	public static func kernelBoot(
		_ name: String = "Kernel Lab", state: VMState = .stopped
	) -> VMInfo {
		var vm = linux(name, state: state)
		let dir = "\(vmsRoot)/\(name)/kernels"
		let kernels = [
			OwnedKernelFile(
				role: .kernel, tag: "6.12", fileName: "vmlinuz", path: "\(dir)/kernel/6.12/vmlinuz",
				overrideCommandLine: "console=hvc0 root=/dev/vda2 debug", overrideEnabled: true),
			OwnedKernelFile(
				role: .kernel, tag: "6.6-lts", fileName: "Image",
				path: "\(dir)/kernel/6.6-lts/Image"),
			OwnedKernelFile(
				role: .initramfs, tag: "6.12", fileName: "initrd.img",
				path: "\(dir)/initramfs/6.12/initrd.img"),
		]
		vm.boot = BootInfo(
			mode: .linuxKernel,
			kernel: KernelSettings(
				kernelPath: kernels[0].path, initrdPath: kernels[2].path,
				commandLine: "console=hvc0 root=/dev/vda2"),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: kernels)
		vm.uartPorts = [
			SerialPortInfo(
				kind: .uart, index: 0,
				guestDevice: SerialPortKind.uart.guestDevice(index: 0, os: .linux),
				logging: SerialLogConfig(mode: .continuous, maxBytes: 16 << 20)),
		]
		vm.devices = (vm.devices ?? []) + [DeviceInfo(kind: .entropy), DeviceInfo(kind: .rosetta)]
		return vm
	}

	// The picker's cast: every state a list row can show.
	public static func library() -> [VMInfo] {
		[
			linux("Debian", state: .running),
			macOS("Sequoia"),
			kernelBoot("Kernel Lab", state: .starting),
			linux("Fedora", state: .error),
			linux("Alpine"),
		]
	}

	// A running copy operation, as the corner progress card shows it.
	public static func copyOperation(vm: String = "Debian") -> OperationInfo {
		OperationInfo(
			id: "op-1", kind: OperationInfo.Kind.copyVM, vm: vm,
			label: "Copying system.raw…", fraction: 0.42,
			completedBytes: 13 << 30, totalBytes: 32 << 30, startedAt: epoch)
	}
}

extension StubMachman {
	// A stub serving `vms` (by name) and the sample host capabilities.
	public static func serving(_ vms: [VMInfo]) -> StubMachman {
		let stub = StubMachman()
		stub.capabilities = Samples.capabilities
		for vm in vms { stub.vms[vm.name] = vm }
		return stub
	}
}
