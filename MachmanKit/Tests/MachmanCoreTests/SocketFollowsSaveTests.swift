//
//  SocketFollowsSaveTests.swift
//  MachmanTests
//
//  E27: a vmhost's control socket is found by its VM's name, so when Save as New VM renames
//  the run, the vmhost moves its live listener to the saved VM's path (rename(2) of a bound
//  socket — connections stay), and the daemon follows it. Before, the run kept answering on
//  the original's path, and a daemon restart adopted it as the original.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// Accepted descriptors, kept open, from the listener's queue.
private final class Accepted: @unchecked Sendable {
	private let lock = NSLock()
	private var fds: [Int32] = []

	func add(_ fd: Int32) { lock.withLock { fds.append(fd) } }
	var all: [Int32] { lock.withLock { fds } }
	func closeAll() { for fd in all { close(fd) } }
}

struct SocketFollowsSaveTests {
	private func scratchDir() throws -> String {
		let dir = TestEnvironment.scratch + "mm-mv-\(getpid())-\(UInt32.random(in: 0..<99999))"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	private func connect(_ path: String) -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard var addr = try? UDSListener.makeAddr(path) else { return -1 }
		let ok = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard ok else { close(fd); return -1 }
		return fd
	}

	private func modified(_ path: String) -> Date {
		let attributes = try? FileManager.default.attributesOfItem(atPath: path)
		return attributes?[.modificationDate] as? Date ?? .distantPast
	}

	private func age(_ path: String) {
		var times = [timeval(tv_sec: 1_577_836_800, tv_usec: 0),
			timeval(tv_sec: 1_577_836_800, tv_usec: 0)]
		_ = utimes(path, &times)
	}

	@Test @MainActor func aMovedListenerAnswersOnlyAtItsNewPath() async throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let accepted = Accepted()
		defer { accepted.closeAll() }
		let listener = try UDSListener(
			path: dir + "/a.sock", queue: DispatchQueue(label: "mm-move"),
			keepAlive: .milliseconds(100)) { fd in accepted.add(fd) }
		let early = connect(dir + "/a.sock")
		defer { close(early) }
		#expect(early >= 0)
		#expect(await eventually(timeout: .seconds(10)) { accepted.all.count == 1 })

		try listener.move(to: dir + "/b.sock")

		#expect(!FileManager.default.fileExists(atPath: dir + "/a.sock"))
		let late = connect(dir + "/b.sock")
		defer { close(late) }
		#expect(late >= 0)
		#expect(await eventually(timeout: .seconds(10)) { accepted.all.count == 2 })
		// The connection made before the move still delivers.
		let served = try #require(accepted.all.first)
		#expect(write(served, "hi", 2) == 2)
		var buffer = [UInt8](repeating: 0, count: 2)
		#expect(read(early, &buffer, 2) == 2)
		#expect(buffer == Array("hi".utf8))
		// The keep-alive touches the path it serves now.
		age(dir + "/b.sock")
		let recent = Date().addingTimeInterval(-60)
		#expect(await eventually(timeout: .seconds(10)) { modified(dir + "/b.sock") > recent })

		listener.shutdown()
		#expect(!FileManager.default.fileExists(atPath: dir + "/b.sock"))
	}

	@Test @MainActor func aMoveNeverTakesALiveSocket() throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let mover = try UDSListener(
			path: dir + "/a.sock", queue: DispatchQueue(label: "mm-move-a")) { close($0) }
		defer { mover.shutdown() }
		let owner = try UDSListener(
			path: dir + "/b.sock", queue: DispatchQueue(label: "mm-move-b")) { close($0) }
		defer { owner.shutdown() }

		#expect(throws: UDSError.self) { try mover.move(to: dir + "/b.sock") }
		#expect(UDSListener.isLive(path: dir + "/a.sock"))
		#expect(UDSListener.isLive(path: dir + "/b.sock"))
	}

	// The vmhost half: promotion moves the server's socket to the saved VM's name-derived path.
	@Test @MainActor func theVMHostFollowsItsSave() throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let alphaPath = MachmanPaths.vmSocketPath(vm: "alpha", runtimeDir: dir)
		let keptPath = MachmanPaths.vmSocketPath(vm: "kept", runtimeDir: dir)
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make()
			defer { host.removeLibrary() }
			let server = MachmanServer(
				api: LocalMachman(registry: host.registry), socketPath: alphaPath,
				daemonVersion: "test")
			try server.start()
			defer { server.stop() }
			VMHostBootstrap.followPromotions(
				of: host.registry, server: server, launchedOn: alphaPath)

			#expect(throws: MachmanError.self) {
				try host.registry.promoteRestrictedVM(to: ".hidden")
			}
			#expect(UDSListener.isLive(path: alphaPath))   // a refused save moves nothing

			_ = try host.registry.promoteRestrictedVM(to: "kept")
			#expect(UDSListener.isLive(path: keptPath))
			#expect(!FileManager.default.fileExists(atPath: alphaPath))
			server.stop()
			#expect(!FileManager.default.fileExists(atPath: keptPath))
		}
	}

	// A host launched elsewhere (not on a name-derived path) is not anyone's to move.
	@Test @MainActor func aHostLaunchedOnAnotherPathStaysThere() throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let custom = dir + "/custom.sock"
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make()
			defer { host.removeLibrary() }
			let server = MachmanServer(
				api: LocalMachman(registry: host.registry), socketPath: custom,
				daemonVersion: "test")
			try server.start()
			defer { server.stop() }
			VMHostBootstrap.followPromotions(of: host.registry, server: server, launchedOn: custom)

			_ = try host.registry.promoteRestrictedVM(to: "kept")
			#expect(UDSListener.isLive(path: custom))
		}
	}

	// MARK: - The daemon's half

	private struct Rig {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
		let client: RemoteMachman
		let alphaPath: String
		let keptPath: String
	}

	@MainActor
	private func adoptSafeRun(names: [String] = ["alpha"]) async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let base = TestEnvironment.scratch + "mm-fs-\(getpid())-\(UInt32.random(in: 0..<99999))"
		let alphaPath = base + "-a.sock"
		let keptPath = base + "-k.sock"
		routing.socketPathForVM = { $0 == "kept" ? keptPath : alphaPath }
		let stub = StubMachman()
		var info = StubMachman.makeInfo("alpha", state: .running)
		info.safeRun = true
		stub.vms["alpha"] = info
		let server = MachmanServer(api: stub, socketPath: alphaPath, daemonVersion: "test")
		try server.start()
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: alphaPath,
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		return Rig(
			routing: routing, stub: stub, server: server, client: client,
			alphaPath: alphaPath, keptPath: keptPath)
	}

	@Test @MainActor func safeSaveFollowsAMovedSocket() async throws {
		let rig = try await adoptSafeRun()
		defer { rig.server.stop() }
		try rig.server.relocate(to: rig.keptPath)   // what a vmhost does before replying

		_ = try await rig.routing.safeSave(vm: "alpha", to: "kept")

		#expect(rig.routing.hostForTesting("kept")?.identity.socketPath == rig.keptPath)
		await rig.client.disconnect()
	}

	@Test @MainActor func anOlderHostKeepsItsPath() async throws {
		let rig = try await adoptSafeRun()
		defer { rig.server.stop() }

		_ = try await rig.routing.safeSave(vm: "alpha", to: "kept")

		#expect(rig.routing.hostForTesting("kept")?.identity.socketPath == rig.alphaPath)
		await rig.client.disconnect()
	}

	@Test @MainActor func theSavedNameIsReservedWhileSaving() async throws {
		let rig = try await adoptSafeRun()
		defer { rig.server.stop() }
		rig.stub.stalled = ["safeSave"]
		let routing = rig.routing
		let save = Task { try await routing.safeSave(vm: "alpha", to: "kept") }

		#expect(await eventually(timeout: .seconds(10)) { rig.stub.calls.contains("safeSave") })
		guard case .starting = routing.residence(of: "kept") else {
			Issue.record("kept should read starting while its save is in flight")
			rig.stub.stalled = []
			_ = try? await save.value
			return
		}
		rig.stub.stalled = []
		_ = try await save.value
		guard case .hosted = routing.residence(of: "kept") else {
			Issue.record("kept should be hosted after the save")
			return
		}
		await rig.client.disconnect()
	}

	// The run stopped (its host went) before the reply was handled: the saved VM is on disk
	// and lists stopped; nothing is re-keyed onto a host that is gone.
	@Test @MainActor func aRunThatEndedDuringTheSaveListsTheSavedVMStopped() async throws {
		let rig = try await adoptSafeRun()
		defer { rig.server.stop() }
		let gone = RoutingMachman.HostedVM(
			identity: RoutingMachman.HostIdentity(
				id: UUID(), name: "alpha", socketPath: rig.alphaPath),
			client: rig.client, app: nil, deathWatch: nil)

		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept")
			_ = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			let info = rig.routing.finishSafeSave(
				gone, from: "alpha", to: "kept",
				reply: StubMachman.makeInfo("kept", state: .running))
			#expect(info.state == .stopped)
		}
		#expect(rig.routing.hostedNames == ["alpha"])   // the live host was not re-keyed
		let kept = try await rig.routing.vm(named: "kept")
		#expect(kept.state == .stopped)
		await rig.client.disconnect()
	}

	// After a daemon restart the saved run is found where it now serves (a regression pin).
	@Test @MainActor func aRestartFindsTheSavedRunAtItsNewPath() async throws {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "kept"] {
				try VMConfig.createNewVMDirectory(name: name)
				_ = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let base = TestEnvironment.scratch + "mm-rs-\(getpid())-\(UInt32.random(in: 0..<99999))"
		let keptPath = base + "-k.sock"
		routing.socketPathForVM = { $0 == "kept" ? keptPath : base + "-a.sock" }
		let stub = StubMachman()
		stub.vms["kept"] = StubMachman.makeInfo("kept", state: .running)
		let server = MachmanServer(api: stub, socketPath: keptPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		await routing.adoptExistingHosts()

		#expect(routing.hostedNames == ["kept"])
		await routing.hostForTesting("kept")?.client.disconnect()
	}
}
