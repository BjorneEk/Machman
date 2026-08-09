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
		let runRoot = NSTemporaryDirectory() + "safe-marker-\(UUID().uuidString)"
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
		let dir = NSTemporaryDirectory() + "safe-absorb-\(UUID().uuidString)"
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
		// Test-owned absolute path: hostGone reads identity.shadowRoot, never the globals.
		let shadowRoot = NSTemporaryDirectory() + "safe-run-\(UUID().uuidString)"
		try FileManager.default.createDirectory(
			atPath: shadowRoot, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: shadowRoot) }

		let socketPath = NSTemporaryDirectory()
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

	@Test @MainActor func safeHostsOverlaySafeRunOnTheWire() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
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
