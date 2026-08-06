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
				minCPUCount: nil, minMemoryBytes: nil),
			consoleLogPath: nil)
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
	func createVM() async throws -> VMInfo {
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
	func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws {
		var vm = try get(name)
		if let cpuCount = cpuCount { vm.cpuCount = cpuCount }
		if let memoryBytes = memoryBytes { vm.memoryBytes = memoryBytes }
		vms[name] = vm
	}
	func addDisk(vm name: String, _ disk: NewDisk) async throws { _ = try get(name) }
	func removeDisk(vm name: String, diskID: String) async throws { _ = try get(name) }
	func addMount(vm name: String, path: String, tag: String) async throws { _ = try get(name) }
	func removeMount(vm name: String, mountID: String) async throws { _ = try get(name) }
	func setKernelBoot(vm name: String, enabled: Bool) async throws { _ = try get(name) }
	func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		_ = try get(name)
	}
	func start(vm name: String, options: StartOptions) async throws {
		var vm = try get(name)
		vm.state = .running
		vm.consoleOpen = options.openConsole
		vms[name] = vm
		emit(.stateChanged(vm: name, state: .running))
	}
	func stop(vm name: String, mode: StopMode) async throws {
		var vm = try get(name)
		vm.state = .stopped
		vm.consoleOpen = false
		vms[name] = vm
		emit(.stateChanged(vm: name, state: .stopped))
	}
	func openConsole(vm name: String) async throws { _ = try get(name) }
	func closeConsole(vm name: String) async throws { _ = try get(name) }
	func consoleInfo(vm name: String) async throws -> ConsoleInfo {
		_ = try get(name)
		return ConsoleInfo(logPath: "/tmp/console.log")
	}
	func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		let vm = try get(name)
		return vm.state.isRunning ? Data([0xFF, 0xD8, 0xFF]) : nil
	}
	func startMacInstall(vm name: String, source: InstallSource) async throws { _ = try get(name) }
	func cancelMacInstall(vm name: String) async throws { _ = try get(name) }
	func macInstallPhase(vm name: String) async throws -> InstallPhase {
		_ = try get(name)
		return InstallPhase(kind: .idle)
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

		try await client.start(vm: "Debian", options: StartOptions(openConsole: false))
		let started = try await client.vm(named: "Debian")
		#expect(started.state == .running)
		#expect(!started.consoleOpen)

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
}
