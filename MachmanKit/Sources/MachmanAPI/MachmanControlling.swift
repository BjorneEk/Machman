//
//  MachmanControlling.swift
//  MachmanAPI
//
//  The seam between interfaces and the VM engine. Phase 1: the GUI talks to an in-process
//  LocalMachman. Phase 2: the same protocol is served over JSON-RPC by the Machmand daemon and
//  consumed through RemoteMachman — clients don't change.
//
//  Everything is DTOs; no live objects cross this boundary. The one deliberate absence is the
//  VM display: VZVirtualMachineView cannot leave the process that owns the VM, so console
//  windows are presented engine-side and only *commands* about them appear here.
//

import Foundation

public protocol MachmanControlling: AnyObject {
	// MARK: Host
	func hostCapabilities() async throws -> HostCapabilities

	// MARK: VM lifecycle
	func listVMs() async throws -> [VMInfo]
	func vm(named name: String) async throws -> VMInfo
	func createVM() async throws -> VMInfo
	func deleteVM(named name: String) async throws
	func renameVM(named name: String, to newName: String) async throws

	// MARK: Configuration
	func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws
	// Mints a fresh persisted MAC; refused while the VM runs (the guest keeps the old one
	// until its next boot, and conflict tracking keys on the live address).
	func regenerateMAC(vm name: String) async throws -> VMInfo
	func addDisk(vm name: String, _ disk: NewDisk) async throws
	func removeDisk(vm name: String, diskID: String) async throws
	func addMount(vm name: String, path: String, tag: String) async throws
	func removeMount(vm name: String, mountID: String) async throws
	func setKernelBoot(vm name: String, enabled: Bool) async throws
	func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws
	func setStartPolicy(vm name: String, policy: StartPolicy) async throws
	// Batch per-id safe flags; unknown ids refuse the WHOLE batch (nothing half-applies).
	func setSafety(vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?) async throws

	// MARK: Run / stop / console
	func start(vm name: String, options: StartOptions) async throws
	func stop(vm name: String, mode: StopMode) async throws
	func openConsole(vm name: String) async throws
	// Close the console window without touching the VM (it keeps running headless).
	func closeConsole(vm name: String) async throws
	func consoleInfo(vm name: String) async throws -> ConsoleInfo
	// A JPEG snapshot of the console window, downscaled to maxWidth; nil when unavailable.
	func preview(vm name: String, maxWidth: Int?) async throws -> Data?

	// MARK: macOS install
	func startMacInstall(vm name: String, source: InstallSource) async throws
	func cancelMacInstall(vm name: String) async throws
	func macInstallPhase(vm name: String) async throws -> InstallPhase

	// MARK: Events
	// Every call returns a fresh stream carrying all events from subscription time on.
	func events() async -> AsyncStream<VMEvent>
}
