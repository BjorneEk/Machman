//
//  MachmanControlling.swift
//  MachmanAPI
//
//  The seam between interfaces and the VM engine. Phase 1: the GUI talks to an in-process
//  LocalMachman. Phase 2: the same protocol is served over JSON-RPC by the MachmanAgent daemon and
//  consumed through RemoteMachman — clients don't change.
//
//  Everything is DTOs; no live objects cross this boundary. The one deliberate absence is the
//  VM display: VZVirtualMachineView cannot leave the process that owns the VM, so VM windows
//  are presented engine-side and only *commands* about them appear here.
//

import Foundation

public protocol MachmanControlling: AnyObject {
	// MARK: Host
	func hostCapabilities() async throws -> HostCapabilities

	// MARK: VM lifecycle
	func listVMs() async throws -> [VMInfo]
	func vm(named name: String) async throws -> VMInfo
	// template: "blank" (no devices, no console) | "default" (implied EFI set + one console;
	// no disk — add your own) | "mac" (mac-guest device set minus trackpad, which needs macOS
	// boot — add it after install). nil keeps the pre-template behavior (same as "default").
	func createVM(template: String?) async throws -> VMInfo
	func deleteVM(named name: String) async throws
	func renameVM(named name: String, to newName: String) async throws
	// Duplicate a stopped VM. diskIDs = writable disks to carry (nil = all); ISOs always
	// travel by reference; mountIDs = mounts to carry (nil = all); the copy gets fresh
	// machine identity and autostart off.
	func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, mountIDs: [String]?,
		regenerateMAC: Bool
	) async throws -> VMInfo

	// MARK: Configuration
	func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws
	// Mints a fresh persisted MAC; refused while the VM runs (the guest keeps the old one
	// until its next boot, and conflict tracking keys on the live address).
	func regenerateMAC(vm name: String) async throws -> VMInfo
	func addDisk(vm name: String, _ disk: NewDisk) async throws
	func removeDisk(vm name: String, diskID: String) async throws
	// Copy an external image INTO the VM dir as an owned disk (magic-sniffed: iso or raw;
	// qcow2 refused). Progress arrives as copyProgress events for the VM.
	func importDisk(vm name: String, path: String) async throws -> VMInfo
	// Copy a referenced external disk into the VM dir, replacing the entry in place
	// (safe flag and row position preserved). Owned entries refuse.
	func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo
	// nil kind = MountKind.virtiofs; MountKind.sshfs is refused for macOS guests.
	func addMount(vm name: String, path: String, tag: String, kind: String?) async throws
	func removeMount(vm name: String, mountID: String) async throws
	func setKernelBoot(vm name: String, enabled: Bool) async throws
	func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws
	// Copy a kernel/initramfs file INTO the VM (owned) and select it; delete removes an owned one.
	func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo
	func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo
	func setStartPolicy(vm name: String, policy: StartPolicy) async throws
	// Batch per-id safe flags; unknown ids refuse the WHOLE batch (nothing half-applies).
	func setSafety(vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?) async throws

	// MARK: Guest devices (1.0.4)
	// One device per kind; add/remove/update take effect at the next start (edits proxy to
	// a running VM's own config like disks do). Kind validity depends on the boot mode.
	func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo
	func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo
	func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo
	// Batch per-entity enabled flags (setSafety twin); serial ports keyed by string index.
	func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	) async throws
	// Per-owned-kernel-file command-line override (replaces KernelSettings.commandLine while
	// that file is the active kernel and the override is enabled). nil fields = unchanged.
	func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo
	// Grow an owned storage disk (shrink refuses); refused while the VM runs.
	func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws -> VMInfo
	// Rename an owned storage disk (backing file moves, so the name-derived id changes);
	// refused while the VM runs.
	func renameDisk(vm name: String, diskID: String, newName: String) async throws -> VMInfo
	// Change a mount's guest tag (next-boot effect, like other mount edits).
	func setMountTag(vm name: String, mountID: String, tag: String) async throws -> VMInfo
	// Change how a mount reaches the guest (1.0.7): MountKind.virtiofs rides the share,
	// MountKind.sshfs is mounted by the guest over its SSH link. Next-boot effect; refused
	// for macOS guests (their share automounts — sshfs would need macFUSE).
	func setMountKind(vm name: String, mountID: String, kind: String) async throws -> VMInfo
	// Re-tag an owned kernel/initramfs file (path + override key migrate); refused while
	// the VM runs.
	func renameKernelFile(vm name: String, path: String, tag: String) async throws -> VMInfo

	// MARK: SSH (1.0.5, alias 1.0.6)
	// Per-VM SSH switches: the managed ~/.ssh entry (integrationEnabled), reverse
	// guest→host approval, and the alias that entry is named after. nil fields leave that
	// half unchanged; an EMPTY alias resets it to the default "<vm>.machman". Refused
	// during safe runs (the daemon-side ~/.ssh effects must never track a discardable
	// shadow write).
	func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo
	// Re-run guest address discovery now. Daemon-only — a vmhost refuses (retire pattern).
	func refreshSSH(vm name: String) async throws
	// Forget everything SSH about a VM: persisted state, the per-VM keypair, and the
	// host-side artifacts (managed config block, pinned host key, reverse key entry).
	func resetSSH(vm name: String) async throws -> VMInfo

	// MARK: Guest setup (1.0.7)
	// Forget the unified installer's report state (config.setup + the report drop-box).
	// The guest keeps what the script installed; SSH state has its own reset.
	func resetSetup(vm name: String) async throws -> VMInfo

	// Whether the share serves the installer payload right now (additive, 1.0.7). ON
	// forces it (the install surface is open — write it live for a running VM); OFF
	// removes an installed guest's payload immediately and lets each boot's copy vanish
	// once its report is ingested, so the share stays clean between installs. Fresh
	// (never-installed) guests always serve.
	func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo

	// MARK: Operations (1.0.4)
	// Live long-running operations, for progress-card resync after reconnect (events have no
	// replay). Terminal states linger briefly; op.cancel cancels a running one.
	func operations() async throws -> [OperationInfo]
	func cancelOperation(id: String) async throws
	// Host-level Rosetta install (system-prompted); reported as an operation.
	func installRosetta() async throws

	// MARK: Serial ports
	// Append/remove a console (virtio) or uart (PL011) port. Ports are fixed at VM start, so
	// these are refused while the VM runs; removal pops the last port of that family.
	func addConsolePort(vm name: String) async throws
	func removeConsolePort(vm name: String) async throws
	func addUartPort(vm name: String) async throws
	func removeUartPort(vm name: String) async throws
	// Retune a port's file logging; applied live when the VM is running.
	func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws

	// MARK: Run / stop / window
	func start(vm name: String, options: StartOptions) async throws
	func stop(vm name: String, mode: StopMode) async throws
	func openWindow(vm name: String) async throws
	// Close the window without touching the VM (it keeps running headless).
	func closeWindow(vm name: String) async throws
	// A JPEG snapshot of the VM window, downscaled to maxWidth; nil when unavailable.
	func preview(vm name: String, maxWidth: Int?) async throws -> Data?

	// MARK: macOS install
	func startMacInstall(vm name: String, source: InstallSource) async throws
	func cancelMacInstall(vm name: String) async throws
	func macInstallPhase(vm name: String) async throws -> InstallPhase

	// Promote a running safe-run shadow to a real VM named newName: the original flips to
	// stopped, the new VM is running (not safe), and its MAC/machine identity regenerate
	// (effective next boot). Refused unless the VM is currently safe-hosted.
	func safeSave(vm name: String, to newName: String) async throws -> VMInfo

	// MARK: Daemon lifecycle
	// Stop serving and exit, leaving vmhosts (and their VMs) running for the successor to
	// re-adopt — quit-leave-VMs-running minus the prompt. Only the daemon honors it; a vmhost
	// refuses.
	func retire() async throws

	// MARK: Events
	// Every call returns a fresh stream carrying all events from subscription time on.
	func events() async -> AsyncStream<VMEvent>
}

extension MachmanControlling {
	// vm.copy before the mount choice: every mount travels.
	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool
	) async throws -> VMInfo {
		try await copyVM(
			vm: name, newName: newName, diskIDs: diskIDs, mountIDs: nil,
			regenerateMAC: regenerateMAC)
	}
}
