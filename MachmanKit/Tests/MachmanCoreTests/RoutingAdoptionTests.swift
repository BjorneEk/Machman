//
//  RoutingAdoptionTests.swift
//  MachmanTests
//
//  E21 and late adoption: the daemon never unlinks a socket something still answers on (a
//  vmhost whose main actor is busy at daemon startup misses hello but is alive — unlinking
//  it made the VM invisible and let the next start spawn a second VZ against the same
//  disks). A vmhost the daemon has not adopted is adopted on first use or by the list.
//  Stub hosts on scratch sockets through the router's socket-path seam; registry setup runs
//  inside the redirected-dir lock, the async surface touches only in-memory state.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// Accepts and holds every connection without ever answering: a live but busy vmhost.
private final class HungHost: @unchecked Sendable {
	private let lock = NSLock()
	private var held: [Int32] = []
	private(set) var listener: UDSListener!

	init(path: String) throws {
		listener = try UDSListener(path: path, queue: DispatchQueue(label: "mm-hung-accept")) {
			[weak self] fd in
			self?.hold(fd)
		}
	}

	private func hold(_ fd: Int32) {
		lock.lock(); held.append(fd); lock.unlock()
	}

	func close() {
		listener.shutdown()
		lock.lock()
		for fd in held { Darwin.close(fd) }
		held = []
		lock.unlock()
	}
}

struct RoutingAdoptionTests {
	@MainActor
	private func makeRouting() throws -> (RoutingMachman, String) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		let socketPath = TestEnvironment.scratch
			+ "mm-adopt-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		routing.socketPathForVM = { _ in socketPath }
		routing.helloDeadline = .milliseconds(200)
		routing.hostProbeDeadline = .milliseconds(300)
		return (routing, socketPath)
	}

	@MainActor
	private func serveStub(at socketPath: String) throws -> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		return (stub, server)
	}

	@Test @MainActor func adoptionKeepsALiveSocketThatMissesHello() async throws {
		let (routing, socketPath) = try makeRouting()
		let host = try HungHost(path: socketPath)
		defer { host.close() }

		await routing.adoptExistingHosts()
		#expect(FileManager.default.fileExists(atPath: socketPath))   // before: unlinked
		#expect(routing.hostedNames.isEmpty)
		#expect(routing.unadoptable == ["alpha"])
	}

	@Test @MainActor func adoptionReclaimsADeadSocket() async throws {
		let (routing, socketPath) = try makeRouting()
		FileManager.default.createFile(atPath: socketPath, contents: nil)   // a SIGKILL leftover

		await routing.adoptExistingHosts()
		#expect(!FileManager.default.fileExists(atPath: socketPath))
		#expect(routing.hostedNames.isEmpty)
		#expect(routing.unadoptable.isEmpty)
	}

	@Test @MainActor func aProxiedCallAdoptsALateVMHost() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveStub(at: socketPath)
		defer { server.stop() }

		try await routing.setHardware(
			vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.calls.contains("setHardware"))   // the host made the edit
		#expect(stub.vms["alpha"]?.cpuCount == 3)
	}

	@Test @MainActor func aListAdoptsALateVMHost() async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try serveStub(at: socketPath)
		defer { server.stop() }

		_ = try await routing.listVMs()
		#expect(await eventually { routing.hostedNames == ["alpha"] })
		let alpha = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(alpha?.state == .running)
	}

	@Test @MainActor func aVMHostThatNeverAnswersListsAsNotResponding() async throws {
		let (routing, socketPath) = try makeRouting()
		let host = try HungHost(path: socketPath)
		defer { host.close() }

		var alpha: VMInfo?
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(3))
		while clock.now < deadline {
			alpha = try await routing.listVMs().first { $0.name == "alpha" }
			if alpha?.unresponsive == true { break }
			try await Task.sleep(for: .milliseconds(50))
		}
		#expect(alpha?.unresponsive == true)
		#expect(alpha?.state == .unknown)
		#expect(routing.hostedNames.isEmpty)
	}

	// A safe run's vmhost adopted late must be a safe run again (its shadow is discarded at
	// stop, never absorbed as the real VM) — and only the marker carrying its pid counts.
	@Test @MainActor func lateAdoptionReattachesItsSafeRun() async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try serveStub(at: socketPath)
		defer { server.stop() }
		let safeDir = TestEnvironment.scratch
			+ "mm-safe-\(getpid())-\(UInt32.random(in: 0..<99999))"
		defer { try? FileManager.default.removeItem(atPath: safeDir) }
		let other = safeDir + "/" + SafeRun.runPrefix + "other"
		try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
		try SafeRun.writeMarker(   // pid 1 is never this host's socket peer
			ShadowMarker(vm: "alpha", createdAt: Date(), pid: 1), runRoot: other)

		let host = try await routing.adoptLiveHost("alpha")
		routing.reattachSafeRun(host, safeDir: safeDir)
		#expect(!host.identity.isSafe)
		#expect(FileManager.default.fileExists(atPath: SafeRun.markerPath(runRoot: other)))

		// The in-process stub's socket peer is this test process.
		let ours = safeDir + "/" + SafeRun.runPrefix + "ours"
		try FileManager.default.createDirectory(atPath: ours, withIntermediateDirectories: true)
		try SafeRun.writeMarker(
			ShadowMarker(vm: "alpha", createdAt: Date(), pid: getpid()), runRoot: ours)
		routing.reattachSafeRun(host, safeDir: safeDir)
		#expect(routing.hostForTesting("alpha")?.identity.isSafe == true)
		#expect(routing.hostForTesting("alpha")?.identity.shadowRoot == ours)
		#expect(FileManager.default.fileExists(atPath: SafeRun.markerPath(runRoot: other)))
	}

	@Test @MainActor func concurrentProxiedCallsAdoptOnce() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try serveStub(at: socketPath)
		defer { server.stop() }

		async let first: Void = routing.setHardware(
			vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
		async let second: Void = routing.setHardware(
			vm: "alpha", cpuCount: nil, memoryBytes: 4096, nestedVirtualization: nil)
		_ = try await (first, second)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.calls.filter { $0 == "setHardware" }.count == 2)
		#expect(routing.adoptionAttempts == 1)   // the second caller joined the first
	}
}
