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

	// Connects, performs the hello handshake, and refuses on api-version mismatch.
	public init(
		socketPath: String = MachmanPaths.daemonSocketPath(),
		clientName: String,
		onDisconnect: @escaping @Sendable () -> Void = {}
	) async throws {
		connection = try RPCConnection(socketPath: socketPath, onDisconnect: onDisconnect)
		hello = try await connection.call(
			.hello, RPCParams.Hello(client: clientName), expecting: RPCResults.Hello.self)
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

	private func void<P: Codable>(_ method: RPCMethod, _ params: P?) async throws {
		_ = try await connection.call(method, params, expecting: RPCEmpty.self)
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
		try await connection.call(.vmGet, RPCParams.Name(name: name), expecting: VMInfo.self)
	}

	public func createVM() async throws -> VMInfo {
		try await connection.call(.vmCreate, RPCEmpty?.none, expecting: VMInfo.self)
	}

	public func deleteVM(named name: String) async throws {
		try await void(.vmDelete, RPCParams.Name(name: name))
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try await void(.vmRename, RPCParams.Rename(name: name, newName: newName))
	}

	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try await connection.call(
			.regenerateMAC, RPCParams.Name(name: name), expecting: VMInfo.self)
	}

	public func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws {
		try await void(.setHardware, RPCParams.SetHardware(
			name: name, cpuCount: cpuCount, memoryBytes: memoryBytes))
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await void(.diskAdd, RPCParams.AddDisk(name: name, disk: disk))
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		try await void(.diskRemove, RPCParams.RemoveDisk(name: name, diskID: diskID))
	}

	public func addMount(vm name: String, path: String, tag: String) async throws {
		try await void(.mountAdd, RPCParams.AddMount(name: name, path: path, tag: tag))
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await void(.mountRemove, RPCParams.RemoveMount(name: name, mountID: mountID))
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await void(.setKernelBoot, RPCParams.SetKernelBoot(name: name, enabled: enabled))
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		try await void(.setStartPolicy, RPCParams.SetStartPolicy(name: name, policy: policy))
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await void(.updateKernelSettings, RPCParams.UpdateKernelSettings(
			name: name, settings: settings))
	}

	public func start(vm name: String, options: StartOptions) async throws {
		try await void(.start, RPCParams.Start(name: name, options: options))
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		try await void(.stop, RPCParams.Stop(name: name, mode: mode))
	}

	public func openConsole(vm name: String) async throws {
		try await void(.consoleOpen, RPCParams.Name(name: name))
	}

	public func closeConsole(vm name: String) async throws {
		try await void(.consoleClose, RPCParams.Name(name: name))
	}

	public func consoleInfo(vm name: String) async throws -> ConsoleInfo {
		try await connection.call(
			.consoleInfo, RPCParams.Name(name: name), expecting: ConsoleInfo.self)
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let result = try await connection.call(
			.preview, RPCParams.Preview(name: name, maxWidth: maxWidth),
			expecting: RPCResults.Preview?.self)
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

	public func events() async -> AsyncStream<VMEvent> {
		// Subscribe on the wire (idempotent server-side), then hand out a local fan-out stream.
		_ = try? await connection.call(
			.eventsSubscribe, RPCEmpty?.none, expecting: RPCEmpty.self)
		return await connection.events()
	}
}
