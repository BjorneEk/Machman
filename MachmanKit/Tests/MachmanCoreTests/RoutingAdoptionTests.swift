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
	// Deadlines: a test against a live in-process stub host gets a generous one, because the
	// stub answers on the main actor, which parallel @MainActor suites keep busy; only the
	// tests that WANT a timeout (a hung host) pass the short ones.
	@MainActor
	private func makeRouting(
		helloDeadline: Duration = .seconds(10), probeDeadline: Duration = .seconds(10)
	) throws -> (RoutingMachman, String) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		let socketPath = TestEnvironment.socketPath("mm-adopt")
		routing.socketPathForVM = { _ in socketPath }
		routing.helloDeadline = helloDeadline
		routing.hostProbeDeadline = probeDeadline
		return (routing, socketPath)
	}

	@MainActor
	private func serveStub(at socketPath: String) throws -> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		return (stub, server)
	}

	@Test @MainActor func adoptionKeepsALiveSocketThatMissesHello() async throws {
		let (routing, socketPath) = try makeRouting(
			helloDeadline: .milliseconds(200), probeDeadline: .milliseconds(300))
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
		let (routing, socketPath) = try makeRouting(
			helloDeadline: .milliseconds(200), probeDeadline: .milliseconds(300))
		let host = try HungHost(path: socketPath)
		defer { host.close() }

		var alpha: VMInfo?
		// The loop ends at the first list that says so; the bound only has to stay under the
		// 10 s default hello deadline, which an adoption ignoring the 200 ms one would wait out.
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(8))
		while clock.now < deadline {
			alpha = try await routing.listVMs().first { $0.name == "alpha" }
			if alpha?.unresponsive == true { break }
			try await Task.sleep(for: .milliseconds(50))
		}
		#expect(alpha?.unresponsive == true)
		#expect(alpha?.state == .unknown)
		#expect(routing.hostedNames.isEmpty)
	}

	// E53: a failed adoption only noted the name, and no event said so: a client that listed
	// the VM before (the agent menu, while startup adoption ran) kept it as unknown and never
	// offered End Process. The first failure has clients list again; a repeat says nothing.
	// The host here accepts and hangs up at once: live, and never adoptable.
	@Test("E53: a vmhost that can't be adopted makes clients list again, once")
	@MainActor func aFailedAdoptionHasClientsListAgainOnce() async throws {
		let (routing, socketPath) = try makeRouting()
		routing.adoptionRetryInterval = .milliseconds(100)
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-unadoptable-accept")) { fd in
				close(fd)
			}
		defer { listener.shutdown() }
		let lists = ListCount()
		let stream = await routing.events()
		let reader = Task { @MainActor in
			for await event in stream where event == .listChanged { lists.count += 1 }
		}
		defer { reader.cancel() }

		let first = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(first?.state == .unknown)   // its adoption has only begun
		#expect(await eventually { lists.count == 1 })
		let listed = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(listed?.unresponsive == true)
		// Its timer asks the host again (E61); the second failure says nothing new.
		#expect(await eventually { routing.adoptionAttempts >= 2 && routing.adoptions.isEmpty })
		try await Task.sleep(for: .milliseconds(200))
		#expect(lists.count == 1)
	}

	// E61: a vmhost that never accepts (frozen, SIGSTOPped) keeps every connect in its accept
	// queue for good, and each list's liveness probe and re-adoption added some. Once the
	// queue was full a connect was refused like a dead socket's: the VM listed stopped,
	// stop-first edits went through under a live VZ, and Start unlinked the socket to spawn a
	// second vmhost on the same disks. This process plays the vmhost serving the path.
	@Test(
		"E61: a vmhost that never accepts keeps listing not responding however often clients list")
	@MainActor func aVMHostThatNeverAcceptsKeepsListingNotResponding() async throws {
		let (routing, socketPath) = try makeRouting(
			helloDeadline: .milliseconds(200), probeDeadline: .milliseconds(300))
		routing.adoptionRetryInterval = .seconds(60)   // no timer tick inside the test
		let host = try FrozenHost(path: socketPath)
		defer { host.close() }
		VMHostProcess.TestHook.setServing(socketPath, getpid())
		defer { VMHostProcess.TestHook.setServing(socketPath, nil) }

		var states: [VMState] = []
		for _ in 0..<50 {
			let alpha = try #require(try await routing.listVMs().first { $0.name == "alpha" })
			states.append(alpha.state)
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(!states.contains(.stopped), "listed \(states)")
		#expect(await eventually { routing.adoptions.isEmpty })
		let listed = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(listed?.state == .unknown)
		#expect(listed?.unresponsive == true)
		#expect(routing.adoptionAttempts == 1)   // tried again on a timer, never on each list
		do {
			try await routing.requireStopped("alpha", "deleting it")
			Issue.record("a stop-first edit went past a live vmhost")
		} catch let error as MachmanError {
			#expect(error.message == "alpha is still running — stop it before deleting it")
		}
		do {
			try await routing.start(vm: "alpha", options: StartOptions())
			Issue.record("a start went past a live vmhost")
		} catch let error as MachmanError {
			#expect(error.message == "alpha is not responding — try again in a moment")
		}
		#expect(FileManager.default.fileExists(atPath: socketPath))   // never unlinked
	}

	// E61 (review F18): a run saved as a new VM moved its socket by renaming it, and the kernel
	// keeps a socket's bind-time address, so once a frozen vmhost's queue at the moved path was
	// full nothing told its listener from a dead socket's. Its retry timer added connects every
	// 5 s: minutes later the saved VM listed stopped, and a Start spawned a second vmhost on its
	// disks. A move binds a listener for the new path now.
	@Test("E61: a frozen vmhost serving a saved VM's moved socket never lists stopped")
	@MainActor func aFrozenVMHostAtAMovedSocketNeverListsStopped() async throws {
		let (routing, socketPath) = try makeRouting(
			helloDeadline: .milliseconds(200), probeDeadline: .milliseconds(300))
		routing.adoptionRetryInterval = .milliseconds(50)   // its timer runs meanwhile
		// The run was launched on another VM's path and saved as alpha: it serves alpha's now.
		let queue = DispatchQueue(label: "mm-moved-accept")
		let listener = try UDSListener(
			path: TestEnvironment.socketPath("mm-launched"), queue: queue) { close($0) }
		try listener.move(to: socketPath)
		queue.suspend()   // frozen: nothing accepts any more
		defer {
			queue.resume()
			listener.shutdown()
		}
		VMHostProcess.TestHook.setServing(socketPath, getpid())   // this process plays it
		defer { VMHostProcess.TestHook.setServing(socketPath, nil) }
		#expect(FrozenHost.fill(socketPath) > 0)   // its accept queue is full

		var states: [VMState] = []
		let clock = ContinuousClock()
		let until = clock.now.advanced(by: .seconds(1))
		while clock.now < until {
			let alpha = try #require(try await routing.listVMs().first { $0.name == "alpha" })
			states.append(alpha.state)
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(!states.contains(.stopped), "listed \(states)")
		#expect(await eventually { routing.adoptionAttempts >= 3 })   // and never read it dark
		let listed = try await routing.listVMs().first { $0.name == "alpha" }
		#expect(listed?.unresponsive == true)
		do {
			try await routing.start(vm: "alpha", options: StartOptions())
			Issue.record("a start went past a live vmhost")
		} catch let error as MachmanError {
			#expect(error.message == "alpha is not responding — try again in a moment")
		}
		#expect(FileManager.default.fileExists(atPath: socketPath))   // never unlinked
	}

	// A safe run's vmhost adopted late must be a safe run again (its shadow is discarded at
	// stop, never absorbed as the real VM) — and only the marker carrying its pid counts.
	@Test @MainActor func lateAdoptionReattachesItsSafeRun() async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try serveStub(at: socketPath)
		defer { server.stop() }
		let safeDir = TestEnvironment.socketPath("mm-safe", suffix: "")
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

	// E43: startup adoption asked one surviving vmhost at a time, and every request waits for
	// it — two or three busy hosts outlasted a client's first vm.list (30 s). Both hosts here
	// hold their first answer; each is asked before either answers. One at a time, the second
	// was asked only once the first's (here 30 s) deadline ran out.
	@Test @MainActor func startupAdoptsSurvivingHostsAtOnce() async throws {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		routing.hostProbeDeadline = .seconds(30)
		let paths = [
			"alpha": TestEnvironment.socketPath("mm-boot-a"),
			"beta": TestEnvironment.socketPath("mm-boot-b"),
		]
		routing.socketPathForVM = { paths[$0] ?? $0 + ".none" }
		var stubs: [StubMachman] = []
		var servers: [MachmanServer] = []
		for name in ["alpha", "beta"] {
			let stub = StubMachman()
			stub.vms[name] = StubMachman.makeInfo(name, state: .running)
			stub.stalled = ["vm"]
			let server = MachmanServer(
				api: stub, socketPath: paths[name]!, daemonVersion: "test")
			try startServing(server)
			stubs.append(stub)
			servers.append(server)
		}
		defer {
			for stub in stubs { stub.stalled = [] }
			for server in servers { server.stop() }
		}

		let adoption = Task { await routing.adoptExistingHosts() }
		#expect(await eventually { stubs.allSatisfy { $0.calls.contains("vm") } })
		for stub in stubs { stub.stalled = [] }
		await adoption.value
		#expect(routing.hostedNames.sorted() == ["alpha", "beta"])
	}
}

@MainActor
private final class ListCount {
	var count = 0
}
