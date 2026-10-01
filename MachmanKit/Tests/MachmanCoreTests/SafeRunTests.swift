//
//  SafeRunTests.swift
//  MachmanTests
//
//  The safe-run building blocks: the policy mapping onto VMCopyRequest, the shadow marker,
//  the history copy-back, and the daemon-side shadow cleanup at hostGone. Config setup uses
//  the seed-decode trick (VMCopierTests pattern); the routing-level test follows the
//  MacConflict pattern — sync registry setup under the redirect lock, async socket work
//  after, against test-owned absolute paths only.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct SafeRunTests {
	private func makeConfig(
		name: String = "alpha",
		disks: [VMDisk] = [],
		mounts: [HostMountPoint] = []
	) throws -> VMConfig {
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.name = name
		config.disks = disks
		config.mountPoints = mounts
		return config
	}

	@Test func shadowRequestMapsThePolicyTable() throws {
		let safeStorage = VMDisk(kind: .storage("data", 0), safe: true)
		let unsafeStorage = VMDisk(kind: .storage("scratch", 0), safe: false)
		let iso = VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/d.iso")), safe: true)
		let safeExternal = VMDisk(
			kind: .fromUrl(URL(fileURLWithPath: "/imgs/a.img")), safe: true)
		let unsafeExternal = VMDisk(
			kind: .fromUrl(URL(fileURLWithPath: "/imgs/b.img")), safe: false)
		let safeMount = HostMountPoint(path: "/x/safe", tag: "s")
		var unsafeMount = HostMountPoint(path: "/x/unsafe", tag: "u")
		unsafeMount.safe = false
		let config = try makeConfig(
			disks: [safeStorage, unsafeStorage, iso, safeExternal, unsafeExternal],
			mounts: [safeMount, unsafeMount])

		let request = SafeRun.shadowRequest(
			config: config, sourceDir: "/lib/alpha", runRoot: "/safe/run-1")
		#expect(request.sourceDir == "/lib/alpha")
		#expect(request.destinationParent == "/safe/run-1")
		#expect(request.newName == "alpha")                 // the shadow impersonates
		#expect(request.regenerateMAC == false)
		guard case .impersonate = request.identity else {
			Issue.record("expected impersonate identity")
			return
		}
		guard case .clone = request.diskPolicies[safeStorage.id] else {
			Issue.record("safe storage should clone"); return
		}
		guard case .reference = request.diskPolicies[unsafeStorage.id] else {
			Issue.record("unsafe storage should reference"); return
		}
		guard case .reference = request.diskPolicies[iso.id] else {
			Issue.record("iso should reference"); return
		}
		guard case .clone = request.diskPolicies[safeExternal.id] else {
			Issue.record("safe external should clone"); return
		}
		guard case .reference = request.diskPolicies[unsafeExternal.id] else {
			Issue.record("unsafe external should reference"); return
		}
		#expect(request.includedMountIDs == [unsafeMount.id.uuidString])
	}

	@Test func shadowRequestDetectsMacOSGuests() throws {
		let config = try makeConfig()
		config.boot = .macOS(MacOSBoot(
			installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
		let request = SafeRun.shadowRequest(
			config: config, sourceDir: "/lib/alpha", runRoot: "/safe/run-1")
		guard case .macOS = request.guestKind else {
			Issue.record("expected macOS guest kind")
			return
		}
	}

	@Test func markerRoundTripsAndToleratesGarbage() throws {
		let runRoot = TestEnvironment.scratch + "safe-marker-\(UUID().uuidString)"
		try FileManager.default.createDirectory(
			atPath: runRoot, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: runRoot) }

		let marker = ShadowMarker(
			vm: "alpha", createdAt: Date(timeIntervalSinceReferenceDate: 1000), pid: 42)
		try SafeRun.writeMarker(marker, runRoot: runRoot)
		#expect(SafeRun.readMarker(runRoot: runRoot) == marker)

		try Data("not json".utf8)
			.write(to: URL(fileURLWithPath: SafeRun.markerPath(runRoot: runRoot)))
		#expect(SafeRun.readMarker(runRoot: runRoot) == nil)
		#expect(SafeRun.readMarker(runRoot: runRoot + "-missing") == nil)
	}

	@Test func absorbShadowHistoryCopiesBackMonotonically() throws {
		let dir = TestEnvironment.scratch + "safe-absorb-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let realPath = dir + "/real-config"
		let shadowPath = dir + "/shadow-config"

		let real = try makeConfig()
		real.totalRuntimeSeconds = 40
		try JSONEncoder().encode(real).write(to: URL(fileURLWithPath: realPath))
		let shadow = try makeConfig()
		shadow.lastRan = Date(timeIntervalSinceReferenceDate: 7000)
		shadow.totalRuntimeSeconds = 100
		try JSONEncoder().encode(shadow).write(to: URL(fileURLWithPath: shadowPath))

		SafeRun.absorbShadowHistory(realConfigPath: realPath, shadowConfigPath: shadowPath)
		var absorbed = try JSONDecoder().decode(
			VMConfig.self, from: Data(contentsOf: URL(fileURLWithPath: realPath)))
		#expect(absorbed.lastRan == shadow.lastRan)
		#expect(absorbed.totalRuntimeSeconds == 100)

		// Monotonic: a shadow that somehow reports LESS never shrinks the real total.
		shadow.totalRuntimeSeconds = 10
		try JSONEncoder().encode(shadow).write(to: URL(fileURLWithPath: shadowPath))
		SafeRun.absorbShadowHistory(realConfigPath: realPath, shadowConfigPath: shadowPath)
		absorbed = try JSONDecoder().decode(
			VMConfig.self, from: Data(contentsOf: URL(fileURLWithPath: realPath)))
		#expect(absorbed.totalRuntimeSeconds == 100)

		// Unreadable shadow: the real config is untouched.
		try Data("junk".utf8).write(to: URL(fileURLWithPath: shadowPath))
		SafeRun.absorbShadowHistory(realConfigPath: realPath, shadowConfigPath: shadowPath)
		let untouched = try JSONDecoder().decode(
			VMConfig.self, from: Data(contentsOf: URL(fileURLWithPath: realPath)))
		#expect(untouched.totalRuntimeSeconds == 100)
	}

	@Test func sweepVerdictDecisionTable() {
		let alive: (Int32) -> Bool = { _ in true }
		let dead: (Int32) -> Bool = { _ in false }
		func marker(pid: Int32?) -> ShadowMarker {
			ShadowMarker(vm: "alpha", createdAt: Date(timeIntervalSinceReferenceDate: 0), pid: pid)
		}
		// Unreadable marker: never attachable.
		#expect(SafeRun.sweepVerdict(marker: nil, hostedPeerPID: 7, isPidAlive: alive) == .delete)
		// pid nil: delete when unhosted, keep (never delete under a live host) when hosted.
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: nil), hostedPeerPID: nil, isPidAlive: alive) == .delete)
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: nil), hostedPeerPID: 7, isPidAlive: alive) == .keep)
		// Exact peer match: re-attach.
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: 7), hostedPeerPID: 7, isPidAlive: dead) == .reattach)
		// Peer mismatch: the misattribution case — delete only when the marker pid is dead.
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: 8), hostedPeerPID: 7, isPidAlive: alive) == .keep)
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: 8), hostedPeerPID: 7, isPidAlive: dead) == .delete)
		// Unhosted: a live pid is an unadopted safe vmhost — leave its disks alone.
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: 9), hostedPeerPID: nil, isPidAlive: alive) == .keep)
		#expect(SafeRun.sweepVerdict(
			marker: marker(pid: 9), hostedPeerPID: nil, isPidAlive: dead) == .delete)
	}

	@Test @MainActor func peerPIDIsTheServingProcess() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-peer-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "peer")
		#expect(client.peerPID == getpid())   // in-process server: the peer is us
		await client.disconnect()
	}

	@MainActor
	private func makeRouting() throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		return routing
	}

	@Test @MainActor func hostGoneDiscardsTheShadow() async throws {
		let routing = try makeRouting()
		routing.isProcessAlive = { _ in false }   // the stub host's exit is its server stopping
		// Test-owned absolute path: hostGone reads identity.shadowRoot, never the globals.
		let shadowRoot = TestEnvironment.scratch + "safe-run-\(UUID().uuidString)"
		try FileManager.default.createDirectory(
			atPath: shadowRoot, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: shadowRoot) }

		let socketPath = TestEnvironment.scratch
			+ "mm-shadow-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: shadowRoot)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		#expect(routing.hostedNames == ["alpha"])

		server.stop()   // the socket drops → onDisconnect → hostGone
		for _ in 0..<40 where !routing.hostedNames.isEmpty {
			try? await Task.sleep(for: .milliseconds(100))
		}
		#expect(routing.hostedNames.isEmpty)
		#expect(!FileManager.default.fileExists(atPath: shadowRoot))
	}

	@Test @MainActor func sweepReattachesTheMatchingPeerAndDeletesTheDead() async throws {
		let routing = try makeRouting()
		// Adopt a live in-process host for alpha FIRST (async, outside the lock): its
		// socket peer is this test process.
		let socketPath = TestEnvironment.scratch
			+ "mm-sweep-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)

		// Arrange run roots + act + assert inside ONE redirect block (sweep is synchronous
		// and reads the safe-dir global at call time).
		try VMTestDir.withRedirectedDir {
			let fm = FileManager.default
			func makeRun(_ suffix: String, _ marker: ShadowMarker?) throws -> String {
				let runRoot = machmanSafeDir + "/" + SafeRun.runPrefix + suffix
				try fm.createDirectory(atPath: runRoot, withIntermediateDirectories: true)
				if let marker { try SafeRun.writeMarker(marker, runRoot: runRoot) }
				return runRoot
			}
			let mine = try makeRun("mine", ShadowMarker(
				vm: "alpha", createdAt: Date(), pid: getpid()))
			let stale = try makeRun("stale", ShadowMarker(
				vm: "alpha", createdAt: Date(), pid: 1))          // pid 1 ≠ our peer
			let orphan = try makeRun("orphan", ShadowMarker(
				vm: "beta", createdAt: Date(), pid: 424242))      // unhosted vm
			let unreadable = try makeRun("junk", nil)

			routing.sweepSafeRuns(isPidAlive: { _ in false })     // every foreign pid dead
			#expect(fm.fileExists(atPath: mine))                  // re-attached, kept
			#expect(!fm.fileExists(atPath: stale))
			#expect(!fm.fileExists(atPath: orphan))
			#expect(!fm.fileExists(atPath: unreadable))
		}
		#expect(routing.hostedNames == ["alpha"])
		let info = try await routing.vm(named: "alpha")
		#expect(info.safeRun == true)                             // the re-attach took
		await client.disconnect()
	}

	@Test @MainActor func purgeDeadShadowsScopesToTheVM() throws {
		let routing = try makeRouting()
		try VMTestDir.withRedirectedDir {
			let fm = FileManager.default
			let alphaDead = machmanSafeDir + "/" + SafeRun.runPrefix + "a-dead"
			let alphaLive = machmanSafeDir + "/" + SafeRun.runPrefix + "a-live"
			let betaDead = machmanSafeDir + "/" + SafeRun.runPrefix + "b-dead"
			for (root, vm, pid) in [
				(alphaDead, "alpha", Int32(1)), (alphaLive, "alpha", Int32(2)),
				(betaDead, "beta", Int32(3)),
			] {
				try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
				try SafeRun.writeMarker(
					ShadowMarker(vm: vm, createdAt: Date(), pid: pid), runRoot: root)
			}
			routing.purgeDeadShadows(for: "alpha", isPidAlive: { $0 == 2 })
			#expect(!fm.fileExists(atPath: alphaDead))    // alpha + dead → purged
			#expect(fm.fileExists(atPath: alphaLive))     // alpha + live → untouched
			#expect(fm.fileExists(atPath: betaDead))      // other VM → out of scope
		}
	}

	@Test @MainActor func safeSaveGuardsAndRekeysTheHost() async throws {
		let routing = try makeRouting()

		// Unhosted → invalidState.
		await #expect(throws: MachmanError.self) {
			_ = try await routing.safeSave(vm: "alpha", to: "kept")
		}

		let socketPath = TestEnvironment.scratch
			+ "mm-save-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		var info = StubMachman.makeInfo("alpha", state: .running)
		info.safeRun = true
		stub.vms["alpha"] = info
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		// Adopted but NOT safe → invalidState.
		let plain = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		let client = try await routing.connectHost(identity: plain)
		routing.adopt(identity: plain, client: client)
		await #expect(throws: MachmanError.self) {
			_ = try await routing.safeSave(vm: "alpha", to: "kept")
		}

		// Flip the host safe (what the sweep's re-attach does), then:
		// name collision with a registry VM → alreadyExists (alpha itself is registered).
		routing.hostForTesting("alpha")?.identity.isSafe = true
		routing.hostForTesting("alpha")?.identity.shadowRoot = "/nonexistent"
		do {
			_ = try await routing.safeSave(vm: "alpha", to: "alpha")
			Issue.record("expected alreadyExists")
		} catch let error as MachmanError {
			#expect(error.code == .alreadyExists)
		}

		// The real thing: proxy + re-key. adoptFromDisk will fail against the restored
		// global dir — tolerated and logged, the re-key must still hold.
		let saved = try await routing.safeSave(vm: "alpha", to: "kept")
		#expect(saved.name == "kept")
		#expect(routing.hostedNames == ["kept"])
		let after = try await routing.vm(named: "kept")
		#expect(after.safeRun == nil)   // no longer a safe run
		await client.disconnect()
	}

	@Test @MainActor func setStartPolicyRefusedWhileSafeHosted() async throws {
		let routing = try makeRouting()
		let socketPath = TestEnvironment.scratch
			+ "mm-pol-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)

		do {
			try await routing.setStartPolicy(vm: "alpha", policy: StartPolicy())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
		}
		await client.disconnect()
	}

	@Test @MainActor func safeHostsOverlaySafeRunOnTheWire() async throws {
		let routing = try makeRouting()
		let socketPath = TestEnvironment.scratch
			+ "mm-overlay-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)

		let info = try await routing.vm(named: "alpha")
		#expect(info.safeRun == true)
		await client.disconnect()
	}
}
