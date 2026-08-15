import Testing
import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// End-to-end wire test: MachmanServer and RemoteMachman talking over a real unix socket in
// this process, against an in-memory stub engine. Validates dispatch, DTO round-trips, error
// mapping, and event notifications without touching any data dir.
@MainActor
final class StubMachman: MachmanControlling {
	var vms: [String: VMInfo] = [:]
	private var eventContinuations: [UUID: AsyncStream<VMEvent>.Continuation] = [:]

	static func makeInfo(_ name: String, state: VMState = .stopped) -> VMInfo {
		VMInfo(
			name: name, state: state, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
	}

	func emit(_ event: VMEvent) {
		for continuation in eventContinuations.values {
			continuation.yield(event)
		}
	}

	private func get(_ name: String) throws -> VMInfo {
		guard let vm = vms[name] else { throw MachmanError.notFound(name) }
		return vm
	}

	func hostCapabilities() async throws -> HostCapabilities {
		HostCapabilities(
			maxCPUCount: 8, minMemoryBytes: 1024, maxMemoryBytes: 4096, freeDiskBytes: 42)
	}
	func listVMs() async throws -> [VMInfo] { Array(vms.values).sorted { $0.name < $1.name } }
	func vm(named name: String) async throws -> VMInfo { try get(name) }
	var lastCreateTemplate: String?
	func createVM(template: String?) async throws -> VMInfo {
		lastCreateTemplate = template
		let vm = Self.makeInfo("new-VM\(vms.count + 1)")
		vms[vm.name] = vm
		emit(.listChanged)
		return vm
	}
	func deleteVM(named name: String) async throws {
		_ = try get(name)
		vms[name] = nil
		emit(.listChanged)
	}
	func renameVM(named name: String, to newName: String) async throws {
		var vm = try get(name)
		vm.name = newName
		vms[name] = nil
		vms[newName] = vm
		emit(.listChanged)
	}
	func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool
	) async throws -> VMInfo {
		var copy = try get(name)
		copy.name = newName ?? "\(name) copy"
		guard vms[copy.name] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(copy.name)' already exists")
		}
		vms[copy.name] = copy
		emit(.listChanged)
		return copy
	}
	func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		var vm = try get(name)
		if let cpuCount = cpuCount { vm.cpuCount = cpuCount }
		if let memoryBytes = memoryBytes { vm.memoryBytes = memoryBytes }
		if let nestedVirtualization { vm.nestedVirtualization = nestedVirtualization }
		vms[name] = vm
	}
	func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
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
	func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		var vm = try get(name)
		vm.devices = (vm.devices ?? []).filter { $0.kind != kind }
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
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
	func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	) async throws {
		var vm = try get(name)
		for (id, value) in disks ?? [:] {
			guard let index = vm.disks.firstIndex(where: { $0.id == id }) else {
				throw MachmanError(code: .notFound, message: "no disk '\(id)' on \(name)")
			}
			vm.disks[index].enabled = value ? nil : false
		}
		vms[name] = vm
	}
	func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try get(name)
	}
	func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws -> VMInfo {
		var vm = try get(name)
		guard let index = vm.disks.firstIndex(where: { $0.id == diskID }) else {
			throw MachmanError(code: .notFound, message: "no disk '\(diskID)' on \(name)")
		}
		vm.disks[index].sizeBytes = sizeBytes
		vms[name] = vm
		return vm
	}
	func renameDisk(vm name: String, diskID: String, newName: String) async throws -> VMInfo {
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
	func setMountTag(vm name: String, mountID: String, tag: String) async throws -> VMInfo {
		var vm = try get(name)
		guard let index = vm.mounts.firstIndex(where: { $0.id == mountID }) else {
			throw MachmanError(code: .notFound, message: "no mount '\(mountID)' on \(name)")
		}
		vm.mounts[index].tag = tag
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?
	) async throws -> VMInfo {
		var vm = try get(name)
		var ssh = vm.ssh ?? SSHInfo()
		if let integrationEnabled { ssh.integrationEnabled = integrationEnabled }
		if let reverseApproved { ssh.reverseState = reverseApproved ? .approved : .pending }
		vm.ssh = ssh
		vms[name] = vm
		emit(.sshChanged(vm: name))
		return vm
	}
	func refreshSSH(vm name: String) async throws {
		_ = try get(name)
	}
	func resetSSH(vm name: String) async throws -> VMInfo {
		var vm = try get(name)
		vm.ssh = nil
		vms[name] = vm
		return vm
	}
	func renameKernelFile(vm name: String, path: String, tag: String) async throws -> VMInfo {
		try get(name)
	}
	var ops: [OperationInfo] = []
	func operations() async throws -> [OperationInfo] { ops }
	func cancelOperation(id: String) async throws {
		guard ops.contains(where: { $0.id == id }) else {
			throw MachmanError(code: .notFound, message: "no operation '\(id)'")
		}
		ops.removeAll { $0.id == id }
	}
	func installRosetta() async throws {
		throw MachmanError(code: .invalidState, message: "stub cannot install Rosetta")
	}
	func regenerateMAC(vm name: String) async throws -> VMInfo {
		var vm = try get(name)
		vm.macAddress = "0a:0a:0a:0a:0a:0a"
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func addDisk(vm name: String, _ disk: NewDisk) async throws { _ = try get(name) }
	func removeDisk(vm name: String, diskID: String) async throws { _ = try get(name) }
	func importDisk(vm name: String, path: String) async throws -> VMInfo {
		var vm = try get(name)
		vm.disks.append(DiskInfo(
			id: "storage:imported", type: .storage, name: "imported", path: path,
			sizeBytes: 1024, safe: true, owned: true))
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
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
	func addMount(vm name: String, path: String, tag: String) async throws { _ = try get(name) }
	func removeMount(vm name: String, mountID: String) async throws { _ = try get(name) }
	func setKernelBoot(vm name: String, enabled: Bool) async throws { _ = try get(name) }
	func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		_ = try get(name)
	}
	func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		var vm = try get(name)
		let base = (sourcePath as NSString).lastPathComponent
		let dest = "/vm/\(name)/kernels/\(role.rawValue)/\(tag)/\(base)"
		vm.boot.ownedKernels = (vm.boot.ownedKernels ?? [])
			+ [OwnedKernelFile(role: role, tag: tag, fileName: base, path: dest)]
		let existing = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		vm.boot.kernel = role == .kernel
			? KernelSettings(
				kernelPath: dest, initrdPath: existing.initrdPath, commandLine: existing.commandLine)
			: KernelSettings(
				kernelPath: existing.kernelPath, initrdPath: dest, commandLine: existing.commandLine)
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		var vm = try get(name)
		vm.boot.ownedKernels?.removeAll { $0.path == path }
		vms[name] = vm
		emit(.listChanged)
		return vm
	}
	func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		var vm = try get(name)
		vm.startPolicy = policy
		vms[name] = vm
		emit(.listChanged)
	}
	func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
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
	func addConsolePort(vm name: String) async throws {
		var vm = try get(name)
		let i = vm.consolePorts?.count ?? 0
		vm.consolePorts = (vm.consolePorts ?? []) + [SerialPortInfo(
			kind: .console, index: i, guestDevice: "hvc\(i)", logging: SerialLogConfig())]
		vms[name] = vm
		emit(.listChanged)
	}
	func removeConsolePort(vm name: String) async throws {
		var vm = try get(name)
		guard !(vm.consolePorts ?? []).isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no console ports")
		}
		vm.consolePorts?.removeLast()
		vms[name] = vm
		emit(.listChanged)
	}
	func addUartPort(vm name: String) async throws {
		var vm = try get(name)
		let i = vm.uartPorts?.count ?? 0
		vm.uartPorts = (vm.uartPorts ?? []) + [SerialPortInfo(
			kind: .uart, index: i, guestDevice: "ttyAMA\(i)", logging: SerialLogConfig())]
		vms[name] = vm
		emit(.listChanged)
	}
	func removeUartPort(vm name: String) async throws {
		var vm = try get(name)
		guard !(vm.uartPorts ?? []).isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no UART ports")
		}
		vm.uartPorts?.removeLast()
		vms[name] = vm
		emit(.listChanged)
	}
	func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
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
		}
		vms[name] = vm
		emit(.listChanged)
	}
	func start(vm name: String, options: StartOptions) async throws {
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
	func stop(vm name: String, mode: StopMode) async throws {
		var vm = try get(name)
		vm.state = .stopped
		vm.windowOpen = false
		vms[name] = vm
		emit(.stateChanged(vm: name, state: .stopped))
	}
	// engineErrorsKeepTheirCode flips this: openWindow then throws an untyped engine error.
	var throwCritical = false
	var windowOpens = 0
	func openWindow(vm name: String) async throws {
		if throwCritical { throw VirtualMachineError.critical("boom") }
		_ = try get(name)
		windowOpens += 1
	}
	func closeWindow(vm name: String) async throws { _ = try get(name) }
	// Large enough that its base64 response overflows a socket send buffer — regression
	// guard for partial/EAGAIN writes on the server side.
	var previewPayload = Data([0xFF, 0xD8, 0xFF])

	func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let vm = try get(name)
		return vm.state.isRunning ? previewPayload : nil
	}
	func startMacInstall(vm name: String, source: InstallSource) async throws { _ = try get(name) }
	func cancelMacInstall(vm name: String) async throws { _ = try get(name) }
	func macInstallPhase(vm name: String) async throws -> InstallPhase {
		_ = try get(name)
		return InstallPhase(kind: .idle)
	}
	func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		var vm = try get(name)
		guard vm.safeRun == true else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running in safe mode")
		}
		guard vms[newName] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(newName)' already exists")
		}
		vm.name = newName
		vm.safeRun = nil
		vms[name] = nil
		vms[newName] = vm
		emit(.stateChanged(vm: name, state: .stopped))
		emit(.stateChanged(vm: newName, state: .running))
		emit(.listChanged)
		return vm
	}
	var retired = false
	func retire() async throws {
		retired = true
	}
	func events() async -> AsyncStream<VMEvent> {
		AsyncStream { continuation in
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

struct LoopbackTests {

	@Test @MainActor func sshSetRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "ssh-loop")

		let updated = try await client.setSSH(
			vm: "Debian", integrationEnabled: true, reverseApproved: nil)
		#expect(updated.ssh?.integrationEnabled == true)
		#expect(updated.ssh?.reverseState == SSHInfo.ReverseState.none)
		try await client.refreshSSH(vm: "Debian")
		let cleared = try await client.resetSSH(vm: "Debian")
		#expect(cleared.ssh == nil)
	}

	@Test @MainActor func wireRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory() + "mm-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "loopback")
		#expect(client.hello.apiVersion == MachmanProtocol.apiVersion)
		#expect(client.hello.daemonVersion == "test")

		// Events: subscribe first so mutations below arrive as notifications.
		let events = await client.events()
		var received: [VMEvent] = []
		let collector = Task {
			for await event in events {
				received.append(event)
				if received.count >= 2 { break }
			}
		}

		// Round-trips.
		let caps = try await client.hostCapabilities()
		#expect(caps.freeDiskBytes == 42)
		let list = try await client.listVMs()
		#expect(list.map(\.name) == ["Debian"])

		try await client.start(vm: "Debian", options: StartOptions(openWindow: false))
		let started = try await client.vm(named: "Debian")
		#expect(started.state == .running)
		#expect(!started.windowOpen)

		let preview = try await client.preview(vm: "Debian", maxWidth: nil)
		#expect(preview == Data([0xFF, 0xD8, 0xFF]))

		try await client.stop(vm: "Debian", mode: .force)
		#expect(try await client.preview(vm: "Debian", maxWidth: nil) == nil)

		// Application errors round-trip with their code.
		do {
			_ = try await client.vm(named: "nope")
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
			#expect(error.message.contains("nope"))
		}

		// The two state changes must have arrived, in order.
		await collector.value
		#expect(received == [
			.stateChanged(vm: "Debian", state: .running),
			.stateChanged(vm: "Debian", state: .stopped),
		])

		await client.disconnect()
	}

	@Test @MainActor func regenerateMACRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-mac-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "mac")
		let updated = try await client.regenerateMAC(vm: "Debian")
		#expect(updated.macAddress == "0a:0a:0a:0a:0a:0a")
		#expect(try await client.vm(named: "Debian").macAddress == "0a:0a:0a:0a:0a:0a")
		await client.disconnect()
	}

	@Test @MainActor func serialPortsRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-ser-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "serial")
		try await client.addConsolePort(vm: "Debian")
		try await client.addUartPort(vm: "Debian")
		try await client.addUartPort(vm: "Debian")
		let info = try await client.vm(named: "Debian")
		#expect(info.consolePorts?.count == 1)
		#expect(info.uartPorts?.count == 2)
		#expect(info.uartPorts?[1].guestDevice == "ttyAMA1")

		try await client.setSerialLogging(
			vm: "Debian", kind: .uart, index: 0,
			config: SerialLogConfig(mode: .continuous, maxBytes: 4096))
		let after = try await client.vm(named: "Debian")
		#expect(after.uartPorts?[0].logging == SerialLogConfig(mode: .continuous, maxBytes: 4096))

		try await client.removeUartPort(vm: "Debian")
		#expect(try await client.vm(named: "Debian").uartPorts?.count == 1)

		// Removing past empty, and an unknown index, carry their codes over the wire.
		try await client.removeUartPort(vm: "Debian")
		do {
			try await client.removeUartPort(vm: "Debian")
			Issue.record("expected invalidArgument")
		} catch let error as MachmanError {
			#expect(error.code == .invalidArgument)
		}
		do {
			try await client.setSerialLogging(
				vm: "Debian", kind: .console, index: 9, config: SerialLogConfig())
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		await client.disconnect()
	}

	@Test @MainActor func kernelPromoteRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-krn-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "krn")
		let promoted = try await client.promoteKernelFile(
			vm: "Debian", role: .kernel, sourcePath: "/tmp/vmlinuz", tag: "janus")
		#expect(promoted.boot.kernel?.kernelPath.hasSuffix("/janus/vmlinuz") == true)
		let owned = try #require(promoted.boot.ownedKernels?.first)
		#expect(owned.role == .kernel && owned.tag == "janus" && owned.fileName == "vmlinuz")

		let after = try await client.deleteKernelFile(vm: "Debian", path: owned.path)
		#expect(after.boot.ownedKernels?.isEmpty == true)
		await client.disconnect()
	}

	@Test @MainActor func setStartPolicyRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-pol-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "pol")
		let policy = StartPolicy(windowed: false, safe: true, autostart: true)
		try await client.setStartPolicy(vm: "Debian", policy: policy)
		#expect(try await client.vm(named: "Debian").startPolicy == policy)
		await client.disconnect()
	}

	@Test @MainActor func copyRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-copy-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "copy")
		let copy = try await client.copyVM(
			vm: "Debian", newName: nil, diskIDs: nil, regenerateMAC: true)
		#expect(copy.name == "Debian copy")
		#expect(try await client.listVMs().map(\.name) == ["Debian", "Debian copy"])

		do {
			_ = try await client.copyVM(
				vm: "Debian", newName: "Debian copy", diskIDs: nil, regenerateMAC: true)
			Issue.record("expected alreadyExists")
		} catch let error as MachmanError {
			#expect(error.code == .alreadyExists)
		}
		await client.disconnect()
	}

	@Test @MainActor func setSafetyRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-safe-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("Debian")
		info.disks = [DiskInfo(
			id: "storage:disk", type: .storage, name: "disk", path: nil, sizeBytes: nil)]
		stub.vms["Debian"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "safe")
		try await client.setSafety(vm: "Debian", disks: ["storage:disk": false], mounts: nil)
		#expect(try await client.vm(named: "Debian").disks.first?.safe == false)

		do {
			try await client.setSafety(vm: "Debian", disks: ["storage:bogus": true], mounts: nil)
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		await client.disconnect()
	}

	@Test @MainActor func diskImportAndPromoteRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-imp-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("Debian")
		info.disks = [DiskInfo(
			id: "url:file:///imgs/a.img", type: .image, name: nil, path: "/imgs/a.img",
			sizeBytes: 1024, safe: true, owned: false)]
		stub.vms["Debian"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "imp")
		let imported = try await client.importDisk(vm: "Debian", path: "/imgs/b.raw")
		#expect(imported.disks.contains { $0.name == "imported" && $0.owned == true })

		let promoted = try await client.promoteDisk(
			vm: "Debian", diskID: "url:file:///imgs/a.img")
		#expect(promoted.disks.allSatisfy { $0.owned == true })

		do {
			_ = try await client.promoteDisk(vm: "Debian", diskID: "storage:imported")
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)   // already owned
		}
		await client.disconnect()
	}

	@Test @MainActor func safeSaveRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-save-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var running = StubMachman.makeInfo("Debian", state: .running)
		running.safeRun = true
		stub.vms["Debian"] = running
		stub.vms["Other"] = StubMachman.makeInfo("Other")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "save")
		let saved = try await client.safeSave(vm: "Debian", to: "Debian kept")
		#expect(saved.name == "Debian kept")
		#expect(saved.safeRun == nil)
		#expect(try await client.listVMs().map(\.name) == ["Debian kept", "Other"])

		do {
			_ = try await client.safeSave(vm: "Other", to: "x")
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)   // not a safe run
		}
		await client.disconnect()
	}

	@Test @MainActor func retireRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-ret-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "ret")
		try await client.retire()
		#expect(stub.retired)
		await client.disconnect()
	}

	@Test @MainActor func engineErrorsKeepTheirCode() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-err-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		stub.throwCritical = true
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "err")
		do {
			try await client.openWindow(vm: "Debian")
			Issue.record("expected a throw")
		} catch let error as MachmanError {
			// The boundary catch keeps a machmanCode and a clean message — no leaked
			// "critical(...)" Swift syntax.
			#expect(error.code == .internalError)
			#expect(error.message == "boom")
		}
		await client.disconnect()
	}

	@Test @MainActor func largeResponsesSurviveTheSocket() async throws {
		let socketPath = NSTemporaryDirectory() + "mm-big-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian", state: .running)
		// 2 MiB of noise ≈ a real VM-window JPEG after base64 — far beyond the socket
		// buffer, so the server must handle partial writes.
		stub.previewPayload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "big")
		let echoed = try await client.preview(vm: "Debian", maxWidth: nil)
		#expect(echoed == stub.previewPayload)
		// The connection must still work afterwards.
		#expect(try await client.vm(named: "Debian").name == "Debian")
		await client.disconnect()
	}

	@Test @MainActor func secondDaemonIsRefused() async throws {
		let socketPath = NSTemporaryDirectory() + "mm-dup-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let second = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		#expect(throws: (any Error).self) {
			try second.start()
		}
	}

	// The 1.0.4 additions dispatch end to end: devices, enabled, overrides, resize,
	// operations, templates, nested-virt.
	@Test @MainActor func devicesAndOperationsRoundTrip() async throws {
		let socketPath = NSTemporaryDirectory()
			+ "mm-dev-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var seeded = StubMachman.makeInfo("Debian")
		seeded.disks = [DiskInfo(
			id: "storage:disk", type: .storage, name: "disk", path: nil, sizeBytes: 1024)]
		stub.vms["Debian"] = seeded
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "devices")

		// Templates ride vm.create's new optional params.
		_ = try await client.createVM(template: "mac")
		#expect(stub.lastCreateTemplate == "mac")

		// Device add → update → remove, VMInfo echoed each time.
		var info = try await client.addDevice(vm: "Debian", kind: .entropy)
		#expect(info.devices?.map(\.kind) == [.entropy])
		var device = DeviceInfo(kind: .entropy)
		device.enabled = false
		info = try await client.updateDevice(vm: "Debian", device: device)
		#expect(info.devices?.first?.enabled == false)
		info = try await client.removeDevice(vm: "Debian", kind: .entropy)
		#expect(info.devices?.isEmpty == true)

		// setEnabled: applies by id; unknown ids surface notFound with the daemon's message.
		try await client.setEnabled(
			vm: "Debian", disks: ["storage:disk": false], mounts: nil,
			console: nil, uart: nil)
		let flagged = try await client.vm(named: "Debian")
		#expect(flagged.disks.first?.isEnabled == false)
		do {
			try await client.setEnabled(
				vm: "Debian", disks: ["ghost": true], mounts: nil, console: nil, uart: nil)
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}

		// Kernel override + resize + hardware(nested) round-trip.
		_ = try await client.setKernelOverride(
			vm: "Debian", path: "/k", commandLine: "quiet", overrideEnabled: true)
		let resized = try await client.resizeDisk(
			vm: "Debian", diskID: "storage:disk", sizeBytes: 4096)
		#expect(resized.disks.first?.sizeBytes == 4096)
		try await client.setHardware(
			vm: "Debian", cpuCount: nil, memoryBytes: nil, nestedVirtualization: true)
		let nested = try await client.vm(named: "Debian")
		#expect(nested.nestedVirtualization == true)

		// Operations: list round-trips; cancel of an unknown id is notFound; rosetta refuses.
		stub.ops = [OperationInfo(
			id: "op-1", kind: OperationInfo.Kind.copyVM, vm: "Debian", label: "Copying…",
			startedAt: Date(timeIntervalSince1970: 1_700_000_000))]
		let ops = try await client.operations()
		#expect(ops.map(\.id) == ["op-1"])
		try await client.cancelOperation(id: "op-1")
		#expect(stub.ops.isEmpty)
		do {
			try await client.cancelOperation(id: "op-1")
			Issue.record("expected notFound")
		} catch let error as MachmanError {
			#expect(error.code == .notFound)
		}
		do {
			try await client.installRosetta()
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
		}

		await client.disconnect()
	}
}
