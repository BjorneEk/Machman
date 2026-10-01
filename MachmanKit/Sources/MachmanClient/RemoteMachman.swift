//
//  RemoteMachman.swift
//  MachmanClient
//
//  MachmanControlling spoken over the daemon's socket. Interchangeable with LocalMachman —
//  the GUI (and any future TUI) doesn't know or care which one it holds.
//

import Foundation
import MachmanAPI

public final class RemoteMachman: MachmanControlling {
	private let connection: RPCConnection
	public let hello: RPCResults.Hello
	// The serving process's pid (socket peer) — the daemon's shadow sweep matches it.
	public var peerPID: Int32? { connection.peerPID }

	// Connects, performs the hello handshake, and refuses on api-version mismatch.
	// helloDeadline: the daemon's spawn/adopt retry loops pass a tight bound so a vmhost
	// that accepts but never answers cannot wedge them (E5).
	public init(
		socketPath: String = MachmanPaths.daemonSocketPath(),
		clientName: String,
		helloDeadline: Duration = RPCConnection.defaultCallDeadline,
		onDisconnect: @escaping @Sendable () -> Void = {}
	) async throws {
		connection = try RPCConnection(socketPath: socketPath, onDisconnect: onDisconnect)
		do {
			hello = try await connection.call(
				.hello, RPCParams.Hello(client: clientName),
				expecting: RPCResults.Hello.self, deadline: helloDeadline)
		} catch {
			// A hello timeout leaves the socket open — close it, or every retry in the
			// daemon's connect loops leaks an fd and a reader thread.
			await connection.disconnect()
			throw error
		}
		guard hello.apiVersion == MachmanProtocol.apiVersion else {
			await connection.disconnect()
			throw MachmanError(
				code: .invalidState,
				message: "daemon speaks api v\(hello.apiVersion), "
					+ "client needs v\(MachmanProtocol.apiVersion)")
		}
	}

	public func disconnect() async {
		await connection.disconnect()
	}

	private func void<P: Codable>(
		_ method: RPCMethod, _ params: P?,
		deadline: Duration = RPCConnection.defaultCallDeadline
	) async throws {
		_ = try await connection.call(method, params, expecting: RPCEmpty.self,
			deadline: deadline)
	}

	// MARK: - MachmanControlling

	public func hostCapabilities() async throws -> HostCapabilities {
		try await connection.call(
			.hostCapabilities, RPCEmpty?.none, expecting: HostCapabilities.self)
	}

	public func listVMs() async throws -> [VMInfo] {
		try await connection.call(.vmList, RPCEmpty?.none, expecting: [VMInfo].self)
	}

	public func vm(named name: String) async throws -> VMInfo {
		try await vm(named: name, deadline: RPCConnection.defaultCallDeadline)
	}

	// Deadline seam (not on MachmanControlling): the daemon asks each vmhost with a short
	// bound, so one stalled host cannot hold a list for every client (E20).
	public func vm(named name: String, deadline: Duration) async throws -> VMInfo {
		try await connection.call(
			.vmGet, RPCParams.Name(name: name), expecting: VMInfo.self, deadline: deadline)
	}

	public func createVM(template: String?) async throws -> VMInfo {
		try await connection.call(
			.vmCreate, RPCParams.Create(template: template), expecting: VMInfo.self)
	}

	public func deleteVM(named name: String) async throws {
		try await void(.vmDelete, RPCParams.Name(name: name))
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try await void(.vmRename, RPCParams.Rename(name: name, newName: newName))
	}

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool
	) async throws -> VMInfo {
		// A cross-volume copy is a real byte copy — bounded generously, not at the default.
		try await connection.call(
			.vmCopy,
			RPCParams.Copy(
				name: name, newName: newName, diskIDs: diskIDs, regenerateMAC: regenerateMAC),
			expecting: VMInfo.self, deadline: RPCConnection.slowCallDeadline)
	}

	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try await connection.call(
			.regenerateMAC, RPCParams.Name(name: name), expecting: VMInfo.self)
	}

	public func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		try await void(.setHardware, RPCParams.SetHardware(
			name: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
			nestedVirtualization: nestedVirtualization))
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await void(.diskAdd, RPCParams.AddDisk(name: name, disk: disk))
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		try await void(.diskRemove, RPCParams.RemoveDisk(name: name, diskID: diskID))
	}

	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		// Copies the external image into VM ownership — byte-copy class, like vm.copy.
		try await connection.call(
			.diskImport, RPCParams.ImportDisk(name: name, path: path),
			expecting: VMInfo.self, deadline: RPCConnection.slowCallDeadline)
	}

	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try await connection.call(
			.diskPromote, RPCParams.RemoveDisk(name: name, diskID: diskID),
			expecting: VMInfo.self, deadline: RPCConnection.slowCallDeadline)
	}

	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		try await void(
			.mountAdd, RPCParams.AddMount(name: name, path: path, tag: tag, kind: kind))
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await void(.mountRemove, RPCParams.RemoveMount(name: name, mountID: mountID))
	}

	public func addConsolePort(vm name: String) async throws {
		try await void(.consoleAdd, RPCParams.Name(name: name))
	}

	public func removeConsolePort(vm name: String) async throws {
		try await void(.consoleRemove, RPCParams.Name(name: name))
	}

	public func addUartPort(vm name: String) async throws {
		try await void(.uartAdd, RPCParams.Name(name: name))
	}

	public func removeUartPort(vm name: String) async throws {
		try await void(.uartRemove, RPCParams.Name(name: name))
	}

	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		try await void(.serialSetLogging, RPCParams.SetSerialLogging(
			name: name, kind: kind, index: index, config: config))
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await void(.setKernelBoot, RPCParams.SetKernelBoot(name: name, enabled: enabled))
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		try await void(.setStartPolicy, RPCParams.SetStartPolicy(name: name, policy: policy))
	}

	public func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
		try await void(.setSafety, RPCParams.SetSafety(name: name, disks: disks, mounts: mounts))
	}

	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await connection.call(
			.deviceAdd, RPCParams.DeviceMutation(name: name, kind: kind),
			expecting: VMInfo.self)
	}

	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await connection.call(
			.deviceRemove, RPCParams.DeviceMutation(name: name, kind: kind),
			expecting: VMInfo.self)
	}

	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		try await connection.call(
			.deviceUpdate, RPCParams.DeviceUpdate(name: name, device: device),
			expecting: VMInfo.self)
	}

	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	) async throws {
		try await void(.setEnabled, RPCParams.SetEnabled(
			name: name, disks: disks, mounts: mounts, console: console, uart: uart))
	}

	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		try await connection.call(
			.sshSet,
			RPCParams.SSHSet(
				name: name, integrationEnabled: integrationEnabled,
				reverseApproved: reverseApproved, alias: alias),
			expecting: VMInfo.self)
	}

	public func refreshSSH(vm name: String) async throws {
		try await void(.sshRefresh, RPCParams.Name(name: name))
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		try await connection.call(
			.sshReset, RPCParams.Name(name: name), expecting: VMInfo.self)
	}

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try await connection.call(
			.kernelSetOverride,
			RPCParams.KernelOverride(
				name: name, path: path, commandLine: commandLine,
				overrideEnabled: overrideEnabled),
			expecting: VMInfo.self)
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		try await connection.call(
			.diskResize,
			RPCParams.ResizeDisk(name: name, diskID: diskID, sizeBytes: sizeBytes),
			expecting: VMInfo.self)
	}

	public func renameDisk(vm name: String, diskID: String, newName: String) async throws
		-> VMInfo {
		try await connection.call(
			.diskRename,
			RPCParams.RenameDisk(name: name, diskID: diskID, newName: newName),
			expecting: VMInfo.self)
	}

	public func setMountTag(vm name: String, mountID: String, tag: String) async throws
		-> VMInfo {
		try await connection.call(
			.mountSetTag,
			RPCParams.SetMountTag(name: name, mountID: mountID, tag: tag),
			expecting: VMInfo.self)
	}

	public func setMountKind(vm name: String, mountID: String, kind: String) async throws
		-> VMInfo {
		try await connection.call(
			.mountSetKind,
			RPCParams.SetMountKind(name: name, mountID: mountID, kind: kind),
			expecting: VMInfo.self)
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		try await connection.call(
			.setupServe, RPCParams.SetupServe(name: name, serve: serve),
			expecting: VMInfo.self)
	}

	public func resetSetup(vm name: String) async throws -> VMInfo {
		try await connection.call(
			.setupReset, RPCParams.Name(name: name), expecting: VMInfo.self)
	}

	public func renameKernelFile(vm name: String, path: String, tag: String) async throws
		-> VMInfo {
		try await connection.call(
			.kernelRename,
			RPCParams.RenameKernel(name: name, path: path, tag: tag),
			expecting: VMInfo.self)
	}

	public func operations() async throws -> [OperationInfo] {
		try await operations(deadline: RPCConnection.defaultCallDeadline)
	}

	// Deadline seam, like vm(named:deadline:).
	public func operations(deadline: Duration) async throws -> [OperationInfo] {
		try await connection.call(
			.hostOperations, RPCEmpty?.none, expecting: [OperationInfo].self,
			deadline: deadline)
	}

	public func cancelOperation(id: String) async throws {
		try await void(.operationCancel, RPCParams.CancelOperation(id: id))
	}

	public func installRosetta() async throws {
		// Downloads from Apple behind the scenes — slow-class, not the 30 s default.
		try await void(.installRosetta, RPCEmpty?.none,
			deadline: RPCConnection.slowCallDeadline)
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await void(.updateKernelSettings, RPCParams.UpdateKernelSettings(
			name: name, settings: settings))
	}

	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		try await connection.call(
			.kernelPromote,
			RPCParams.PromoteKernel(
				name: name, role: role, sourcePath: sourcePath, tag: tag),
			expecting: VMInfo.self)
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try await connection.call(
			.kernelDelete, RPCParams.DeleteKernel(name: name, path: path), expecting: VMInfo.self)
	}

	public func start(vm name: String, options: StartOptions) async throws {
		// Covers the daemon's whole start: spawn + forwarded boot, and for safe runs a
		// shadow build that byte-copies external images — slow-class by construction.
		try await void(.start, RPCParams.Start(name: name, options: options),
			deadline: RPCConnection.slowCallDeadline)
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		try await stop(vm: name, mode: mode, deadline: RPCConnection.defaultCallDeadline)
	}

	// Deadline seam (not on MachmanControlling): the daemon's quit path bounds each hosted
	// stop tighter than the default so one wedged vmhost cannot stall the terminate reply.
	public func stop(vm name: String, mode: StopMode, deadline: Duration) async throws {
		try await void(.stop, RPCParams.Stop(name: name, mode: mode), deadline: deadline)
	}

	public func openWindow(vm name: String) async throws {
		try await void(.windowOpen, RPCParams.Name(name: name))
	}

	public func closeWindow(vm name: String) async throws {
		try await void(.windowClose, RPCParams.Name(name: name))
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		try await preview(vm: name, maxWidth: maxWidth, deadline: RPCConnection.defaultCallDeadline)
	}

	// Deadline seam, like vm(named:deadline:).
	public func preview(vm name: String, maxWidth: Int?, deadline: Duration) async throws
		-> Data? {
		let result = try await connection.call(
			.preview, RPCParams.Preview(name: name, maxWidth: maxWidth),
			expecting: RPCResults.Preview?.self, deadline: deadline)
		return result.flatMap { Data(base64Encoded: $0.jpegBase64) }
	}

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		try await void(.installStart, RPCParams.InstallStart(name: name, source: source))
	}

	public func cancelMacInstall(vm name: String) async throws {
		try await void(.installCancel, RPCParams.Name(name: name))
	}

	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		try await connection.call(
			.installPhase, RPCParams.Name(name: name), expecting: InstallPhase.self)
	}

	public func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		// Shadow promotion can copy across volumes (the engine's own caveat) — slow-class.
		try await connection.call(
			.safeSave, RPCParams.Rename(name: name, newName: newName),
			expecting: VMInfo.self, deadline: RPCConnection.slowCallDeadline)
	}

	public func retire() async throws {
		try await void(.daemonRetire, RPCEmpty?.none)
	}

	public func events() async -> AsyncStream<VMEvent> {
		// Subscribe on the wire (idempotent server-side), then hand out a local fan-out stream.
		_ = try? await connection.call(
			.eventsSubscribe, RPCEmpty?.none, expecting: RPCEmpty.self)
		return await connection.events()
	}
}
