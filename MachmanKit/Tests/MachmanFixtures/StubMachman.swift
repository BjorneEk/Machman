//
//  StubMachman.swift
//  MachmanFixtures
//
//  An in-memory MachmanControlling: the engine the wire tests serve over a real socket, the
//  daemon the desktop view-model tests drive, and the backend the render tool's scenes read.
//  Depends on MachmanAPI only. Every call is logged by base name (`calls`), starts are kept
//  with their options, and `fail(_:with:)` scripts a one-shot error for the next call of a
//  method — so a test can assert what the client asked for and how it copes with a refusal.
//

import Foundation
import MachmanAPI

@MainActor
public final class StubMachman: MachmanControlling {
	public var vms: [String: VMInfo] = [:]
	private var eventContinuations: [UUID: AsyncStream<VMEvent>.Continuation] = [:]

	// Every call, by base name ("start", "addDisk", …), in order.
	public private(set) var calls: [String] = []
	// vm.start requests with their options, in order (start-policy assertions).
	public private(set) var starts: [(vm: String, options: StartOptions)] = []
	// One-shot scripted failures by base name: the next call of that method throws.
	private var failures: [String: Error] = [:]
	// Base names whose calls park while listed: a stalled vmhost (E20). They answer once
	// removed, or after a minute. Honored by vm(named:), operations(), preview and safeSave.
	public var stalled: Set<String> = []

	public init() {}

	public static func makeInfo(_ name: String, state: VMState = .stopped) -> VMInfo {
		VMInfo(
			name: name, state: state, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
	}

	// The next call of `method` (a base name: "start", "openWindow", …) throws `error`.
	public func fail(_ method: String, with error: Error) {
		failures[method] = error
	}

	public func emit(_ event: VMEvent) {
		for continuation in eventContinuations.values {
			continuation.yield(event)
		}
	}

	// Log the call and fire its scripted failure, if any. Every method's first statement.
	private func gate(_ function: String = #function) throws {
		let name = String(function.prefix { $0 != "(" })
		calls.append(name)
		if let error = failures.removeValue(forKey: name) {
			throw error
		}
	}

	private func stallWhileScripted(_ name: String) async {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(60))
		while stalled.contains(name), clock.now < deadline {
			try? await Task.sleep(for: .milliseconds(20))
		}
	}

	private func get(_ name: String) throws -> VMInfo {
		guard let vm = vms[name] else { throw MachmanError.notFound(name) }
		return vm
	}

	public var capabilities = HostCapabilities(
		maxCPUCount: 8, minMemoryBytes: 1024, maxMemoryBytes: 4096, freeDiskBytes: 42)
	public func hostCapabilities() async throws -> HostCapabilities {
		try gate()
		return capabilities
	}
	public func listVMs() async throws -> [VMInfo] {
		try gate()
		return Array(vms.values).sorted { $0.name < $1.name }
	}
	public func vm(named name: String) async throws -> VMInfo {
		try gate()
		await stallWhileScripted("vm")
		return try get(name)
	}
	public var lastCreateTemplate: String?
	public func createVM(template: String?) async throws -> VMInfo {
		try gate()
		lastCreateTemplate = template
		let vm = Self.makeInfo("new-VM\(vms.count + 1)")
		vms[vm.name] = vm
		emit(.listChanged)
		return vm
	}
	public func deleteVM(named name: String) async throws {
		try gate()
		_ = try get(name)
		vms[name] = nil
		emit(.listChanged)
	}
	public func renameVM(named name: String, to newName: String) async throws {
		try gate()
		var vm = try get(name)
		vm.name = newName
		vms[name] = nil
		vms[newName] = vm
		emit(.listChanged)
	}
	// vm.copy requests with what they asked to carry, in order.
	public private(set) var copies: [(vm: String, diskIDs: [String]?, mountIDs: [String]?)] = []
	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, mountIDs: [String]?,
		regenerateMAC: Bool
	) async throws -> VMInfo {
		try gate()
		copies.append((name, diskIDs, mountIDs))
		var copy = try get(name)
		copy.name = newName ?? "\(name) copy"
		if let mountIDs { copy.mounts.removeAll { !mountIDs.contains($0.id) } }
		guard vms[copy.name] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(copy.name)' already exists")
		}
		vms[copy.name] = copy
		emit(.listChanged)
		return copy
	}
	public func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		try gate()
		var vm = try get(name)
		if let cpuCount = cpuCount { vm.cpuCount = cpuCount }
		if let memoryBytes = memoryBytes { vm.memoryBytes = memoryBytes }
		if let nestedVirtualization { vm.nestedVirtualization = nestedVirtualization }
		vms[name] = vm
	}
	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		var devices = vm.devices ?? []
		guard !devices.contains(where: { $0.kind == kind }) else {
			throw MachmanError(
				code: .alreadyExists, message: "\(name) already has a \(kind.rawValue) device")
		}
		devices.append(DeviceInfo(kind: kind))
		vm.devices = devices
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.devices = (vm.devices ?? []).filter { $0.kind != kind }
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		var devices = vm.devices ?? []
		guard let index = devices.firstIndex(where: { $0.kind == device.kind }) else {
			throw MachmanError(
				code: .notFound, message: "no \(device.kind.rawValue) device on \(name)")
		}
		devices[index] = device
		vm.devices = devices
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	// vm.setEnabled requests as sent (past the gate), in order — unknown ids included.
	public private(set) var enabledChanges: [(
		vm: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	)] = []
	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	) async throws {
		try gate()
		enabledChanges.append((name, disks, mounts, console, uart))
		var vm = try get(name)
		for (id, value) in disks ?? [:] {
			guard let index = vm.disks.firstIndex(where: { $0.id == id }) else {
				throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
			}
			vm.disks[index].enabled = value ? nil : false
		}
		vms[name] = vm
	}
	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try gate()
		return try get(name)
	}
	public func resizeDisk(
		vm name: String, diskID: String, sizeBytes: UInt64
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		guard let index = vm.disks.firstIndex(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(diskID)' on \(name)")
		}
		vm.disks[index].sizeBytes = sizeBytes
		vms[name] = vm
		return vm
	}
	public func renameDisk(
		vm name: String, diskID: String, newName: String
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		guard let index = vm.disks.firstIndex(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(diskID)' on \(name)")
		}
		vm.disks[index].name = newName
		vm.disks[index].id = "storage:\(newName)"
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func setMountTag(
		vm name: String, mountID: String, tag: String
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		guard let index = vm.mounts.firstIndex(where: { $0.id == mountID }) else {
			throw MachmanError(code: .notFound, message: "no mount '\(mountID)' on \(name)")
		}
		vm.mounts[index].tag = tag
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func setMountKind(
		vm name: String, mountID: String, kind: String
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		guard let index = vm.mounts.firstIndex(where: { $0.id == mountID }) else {
			throw MachmanError(code: .notFound, message: "no mount '\(mountID)' on \(name)")
		}
		vm.mounts[index].kind = kind
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		var ssh = vm.ssh ?? SSHInfo()
		if let integrationEnabled { ssh.integrationEnabled = integrationEnabled }
		if let reverseApproved { ssh.reverseState = reverseApproved ? .approved : .pending }
		if let alias { ssh.alias = alias.isEmpty ? nil : alias }
		vm.ssh = ssh
		vms[name] = vm
		emit(.sshChanged(vm: name))
		return vm
	}
	public func refreshSSH(vm name: String) async throws {
		try gate()
		_ = try get(name)
	}
	public func resetSSH(vm name: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.ssh = nil
		vms[name] = vm
		return vm
	}
	public var served: [String: Bool] = [:]
	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		try gate()
		served[name] = serve
		return try get(name)
	}
	public func resetSetup(vm name: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.setup = nil
		vms[name] = vm
		return vm
	}
	public func renameKernelFile(
		vm name: String, path: String, tag: String
	) async throws -> VMInfo {
		try gate()
		return try get(name)
	}
	public var ops: [OperationInfo] = []
	public func operations() async throws -> [OperationInfo] {
		try gate()
		await stallWhileScripted("operations")
		return ops
	}
	public func cancelOperation(id: String) async throws {
		try gate()
		guard ops.contains(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "no operation '\(id)'")
		}
		ops.removeAll { $0.id == id }
	}
	public func installRosetta() async throws {
		try gate()
		throw MachmanError(code: .invalidState, message: "stub cannot install Rosetta")
	}
	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.macAddress = "0a:0a:0a:0a:0a:0a"
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	// Disk adds as the client sent them, in order (the Add flows' assertions).
	public private(set) var addedDisks: [(vm: String, disk: NewDisk)] = []
	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try gate()
		_ = try get(name)
		addedDisks.append((name, disk))
	}
	public func removeDisk(vm name: String, diskID: String) async throws {
		try gate()
		_ = try get(name)
	}
	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.disks.append(DiskInfo(
			id: "storage:imported", type: .storage, name: "imported", path: path,
			sizeBytes: 1024, safe: true, owned: true))
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		guard let index = vm.disks.firstIndex(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(diskID)' on \(name)")
		}
		guard vm.disks[index].owned != true else {
			throw MachmanError(
				code: .invalidState, message: "this disk is already owned by the VM")
		}
		vm.disks[index].owned = true
		vm.disks[index].type = .storage
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		try gate()
		var vm = try get(name)
		vm.mounts.append(MountInfo(
			id: UUID().uuidString, path: path, tag: tag, kind: kind))
		vms[name] = vm
	}
	public func removeMount(vm name: String, mountID: String) async throws {
		try gate()
		_ = try get(name)
	}
	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try gate()
		_ = try get(name)
	}
	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try gate()
		_ = try get(name)
	}
	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		let base = (sourcePath as NSString).lastPathComponent
		let dest = "/vm/\(name)/kernels/\(role.rawValue)/\(tag)/\(base)"
		vm.boot.ownedKernels = (vm.boot.ownedKernels ?? [])
			+ [OwnedKernelFile(role: role, tag: tag, fileName: base, path: dest)]
		let existing = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		vm.boot.kernel = role == .kernel
			? KernelSettings(
				kernelPath: dest, initrdPath: existing.initrdPath,
				commandLine: existing.commandLine)
			: KernelSettings(
				kernelPath: existing.kernelPath, initrdPath: dest,
				commandLine: existing.commandLine)
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try gate()
		var vm = try get(name)
		vm.boot.ownedKernels?.removeAll { $0.path == path }
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		try gate()
		var vm = try get(name)
		vm.startPolicy = policy
		vms[name] = vm
		emit(.listChanged)
	}
	public func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
		try gate()
		var vm = try get(name)
		for (id, safe) in disks ?? [:] {
			guard let index = vm.disks.firstIndex(where: { $0.id == id }) else {
				throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
			}
			vm.disks[index].safe = safe
		}
		for (id, safe) in mounts ?? [:] {
			guard let index = vm.mounts.firstIndex(where: { $0.id == id }) else {
				throw MachmanError(code: .notFound, message: "no mount '\(id)' on \(name)")
			}
			vm.mounts[index].safe = safe
		}
		vms[name] = vm
		emit(.listChanged)
	}
	public func addConsolePort(vm name: String) async throws {
		try gate()
		var vm = try get(name)
		let i = vm.consolePorts?.count ?? 0
		vm.consolePorts = (vm.consolePorts ?? []) + [SerialPortInfo(
			kind: .console, index: i, guestDevice: "hvc\(i)", logging: SerialLogConfig())]
		vms[name] = vm
		emit(.listChanged)
	}
	public func removeConsolePort(vm name: String) async throws {
		try gate()
		var vm = try get(name)
		guard !(vm.consolePorts ?? []).isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no console ports")
		}
		vm.consolePorts?.removeLast()
		vms[name] = vm
		emit(.listChanged)
	}
	public func addUartPort(vm name: String) async throws {
		try gate()
		var vm = try get(name)
		let i = vm.uartPorts?.count ?? 0
		vm.uartPorts = (vm.uartPorts ?? []) + [SerialPortInfo(
			kind: .uart, index: i, guestDevice: "ttyAMA\(i)", logging: SerialLogConfig())]
		vms[name] = vm
		emit(.listChanged)
	}
	public func removeUartPort(vm name: String) async throws {
		try gate()
		var vm = try get(name)
		guard !(vm.uartPorts ?? []).isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no UART ports")
		}
		vm.uartPorts?.removeLast()
		vms[name] = vm
		emit(.listChanged)
	}
	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		try gate()
		var vm = try get(name)
		switch kind {
		case .console:
			guard var ports = vm.consolePorts, ports.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "no console port \(index)")
			}
			ports[index].logging = config
			vm.consolePorts = ports
		case .uart:
			guard var ports = vm.uartPorts, ports.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "no UART port \(index)")
			}
			ports[index].logging = config
			vm.uartPorts = ports
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "unknown serial port kind")
		}
		vms[name] = vm
		emit(.listChanged)
	}
	public func start(vm name: String, options: StartOptions) async throws {
		try gate()
		starts.append((name, options))
		var vm = try get(name)
		guard !vm.state.isRunning else {
			// Mirrors the engine so probe-adopt's already-running arm is exercisable.
			throw MachmanError(code: .invalidState, message: "\(name) is already running")
		}
		vm.state = .running
		vm.windowOpen = options.openWindow
		vms[name] = vm
		emit(.stateChanged(vm: name, state: .running))
	}
	public func stop(vm name: String, mode: StopMode) async throws {
		try gate()
		var vm = try get(name)
		vm.state = .stopped
		vm.windowOpen = false
		vms[name] = vm
		emit(.stateChanged(vm: name, state: .stopped))
	}
	public var windowOpens = 0
	public func openWindow(vm name: String) async throws {
		try gate()
		_ = try get(name)
		windowOpens += 1
	}
	public func closeWindow(vm name: String) async throws {
		try gate()
		_ = try get(name)
	}
	// Large enough that its base64 response overflows a socket send buffer — regression
	// guard for partial/EAGAIN writes on the server side.
	public var previewPayload = Data([0xFF, 0xD8, 0xFF])

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		try gate()
		await stallWhileScripted("preview")
		let vm = try get(name)
		return vm.state.isRunning ? previewPayload : nil
	}
	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		try gate()
		_ = try get(name)
	}
	public func cancelMacInstall(vm name: String) async throws {
		try gate()
		_ = try get(name)
	}
	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		try gate()
		_ = try get(name)
		return InstallPhase(kind: .idle)
	}
	// The engine keeps the original VM after a save (stopped, its run handed to the new
	// name); the stub drops it unless this is set (LoopbackTests pins the dropping list).
	public var safeSaveKeepsOriginal = false
	// What a vmhost's save leaves on disk before it answers (the files it moved, the configs
	// it rewrote). Runs ahead of the gate, so a scripted failure leaves it behind too.
	public var onSafeSave: ((_ vm: String, _ newName: String) -> Void)?
	public func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		onSafeSave?(name, newName)
		try gate()
		await stallWhileScripted("safeSave")
		var vm = try get(name)
		guard vm.safeRun == true else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running in safe mode")
		}
		guard vms[newName] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(newName)' already exists")
		}
		var original = vm
		vm.name = newName
		vm.safeRun = nil
		vms[name] = nil
		if safeSaveKeepsOriginal {
			original.state = .stopped
			original.safeRun = nil
			original.windowOpen = false
			original.consolePorts = original.consolePorts?.map { port in
				var port = port
				port.socketPath = nil
				return port
			}
			original.uartPorts = original.uartPorts?.map { port in
				var port = port
				port.socketPath = nil
				return port
			}
			vms[name] = original
		}
		vms[newName] = vm
		emit(.stateChanged(vm: name, state: .stopped))
		emit(.stateChanged(vm: newName, state: .running))
		emit(.listChanged)
		return vm
	}
	public var retired = false
	public func retire() async throws {
		try gate()
		retired = true
	}
	public func events() async -> AsyncStream<VMEvent> {
		calls.append("events")
		return AsyncStream { continuation in
			let id = UUID()
			eventContinuations[id] = continuation
			continuation.onTermination = { _ in
				Task { @MainActor [weak self] in
					self?.eventContinuations[id] = nil
				}
			}
		}
	}
}
