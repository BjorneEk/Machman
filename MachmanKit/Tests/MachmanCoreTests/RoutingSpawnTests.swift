//
//  RoutingSpawnTests.swift
//  MachmanCoreTests
//
//  A start's spawn, through the launch seam: the router launches nothing here — the seam
//  hands back a stand-in process and serves an in-process stub vmhost on the VM's socket, as
//  the launched vmhost would. E62: the spawn took the first connection that answered on the
//  socket, whoever served it.
//

import Testing
import Foundation
import AppKit
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// A launched vmhost as the router sees it: a pid and an exit. Ending it runs `onEnd` once
// (a test stops the stub host it stands for); `ended` counts the ends that took.
final class StandInVMHostApp: VMHostApp, @unchecked Sendable {
	let processIdentifier: pid_t
	private(set) var isTerminated: Bool
	private(set) var ended = 0
	var onEnd: () -> Void = {}
	private var watchers: [UUID: @Sendable () -> Void] = [:]

	init(pid: pid_t = getpid(), terminated: Bool = false) {
		processIdentifier = pid
		isTerminated = terminated
	}

	@discardableResult
	func forceTerminate() -> Bool {
		guard !isTerminated else { return true }
		ended += 1
		isTerminated = true
		onEnd()
		for watcher in watchers.values { watcher() }
		return true
	}

	func watchTermination(_ handler: @escaping @Sendable () -> Void) -> VMHostAppWatch {
		let id = UUID()
		watchers[id] = handler
		return Watch { [weak self] in self?.watchers[id] = nil }
	}

	private final class Watch: VMHostAppWatch {
		let end: () -> Void
		init(_ end: @escaping () -> Void) { self.end = end }
		func invalidate() { end() }
	}
}

struct RoutingSpawnTests {
	struct Rig {
		let routing: RoutingMachman
		let socketPath: String
	}

	@MainActor
	static func makeRig(_ tag: String) throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		let socketPath = TestEnvironment.socketPath("mm-\(tag)")
		routing.socketPathForVM = { _ in socketPath }
		// Found, and launched only through the seam each test sets.
		routing.locateVMHost = {
			let app = URL(fileURLWithPath: "/nonexistent/MachmanVMHost.app")
			return VMHostLocation(appURL: app, executableURL: app)
		}
		routing.launchVMHost = { _, _ in
			Issue.record("a launch the test didn't stage")
			return StandInVMHostApp(terminated: true)
		}
		routing.hostProbeDeadline = .seconds(10)
		return Rig(routing: routing, socketPath: socketPath)
	}

	// A stub vmhost for alpha, serving on `path` from the moment the launch happens.
	@MainActor
	static func stubHost(_ path: String, state: VMState = .stopped) throws
		-> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: state)
		let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
		return (stub, server)
	}

	@Test("E62: a spawn through the launch seam hosts the vmhost it launched")
	@MainActor func aSpawnHostsTheVMHostItLaunched() async throws {
		let rig = try Self.makeRig("spawn")
		let (stub, server) = try Self.stubHost(rig.socketPath)
		defer { server.stop() }
		let app = StandInVMHostApp()
		var arguments: [String] = []
		rig.routing.launchVMHost = { _, configuration in
			arguments = configuration.arguments
			try startServing(server)
			return app
		}

		try await rig.routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		let host = try #require(rig.routing.hostForTesting("alpha"))
		#expect(host.app === app)
		#expect(stub.calls.contains("start"))
		#expect(arguments.contains("--vm") && arguments.contains("alpha"))
		#expect(arguments.contains(rig.socketPath))
	}

	// A pid that isn't this test process's: the stub hosts are served by this process, so a
	// launched app with this pid did not bind them.
	static let notThisProcess: pid_t = getppid()

	// E62: a launch-agent vmhost for the same VM that binds first (a login boot racing a Start)
	// answered the spawn's connect. The forwarded start's "already running" failed the start,
	// and the cleanup unlinked that vmhost's live socket: its VM turned invisible and
	// unstoppable, and the next Start booted a second VZ on its disks.
	@Test("E62: a spawn answered by another vmhost adopts it and leaves its socket")
	@MainActor func aSpawnAnsweredByAnotherVMHostAdoptsIt() async throws {
		let rig = try Self.makeRig("foreign")
		let (stub, server) = try Self.stubHost(rig.socketPath, state: .running)
		defer { server.stop() }
		let ours = StandInVMHostApp(pid: Self.notThisProcess)   // still launching
		rig.routing.launchVMHost = { _, _ in
			try startServing(server)   // the other vmhost, bound first
			return ours
		}

		try await rig.routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		let host = try #require(rig.routing.hostForTesting("alpha"))
		#expect(host.app == nil)   // adopted: not the app this start launched
		#expect(ours.ended == 1)
		#expect(stub.calls.contains("start"))
		#expect(FileManager.default.fileExists(atPath: rig.socketPath))
	}

	@Test(
		"""
		E62: a vmhost that quit because its socket was served hands the start to the one \
		serving it
		""")
	@MainActor func aVMHostThatQuitOnAServedSocketHandsTheStartOver() async throws {
		let rig = try Self.makeRig("quit65")
		let (stub, server) = try Self.stubHost(rig.socketPath, state: .running)
		defer { server.stop() }
		// Ours found the path taken and quit (exit 65) before the spawn first asked.
		let ours = StandInVMHostApp(pid: Self.notThisProcess, terminated: true)
		rig.routing.launchVMHost = { _, _ in
			try startServing(server)
			return ours
		}

		// Before: "Machman VM for alpha didn’t start: It quit while starting".
		try await rig.routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		#expect(rig.routing.hostForTesting("alpha")?.app == nil)
		#expect(stub.calls.contains("start"))
		#expect(FileManager.default.fileExists(atPath: rig.socketPath))
	}

	@Test("E62: an abandoned spawn never unlinks a socket that still answers")
	@MainActor func anAbandonedSpawnNeverUnlinksALiveSocket() async throws {
		let rig = try Self.makeRig("abandon")
		let (stub, server) = try Self.stubHost(rig.socketPath)
		defer { server.stop() }
		stub.fail("start", with: MachmanError(code: .internalError, message: "no boot"))
		let ours = StandInVMHostApp()   // ours; still serving as it is ended
		rig.routing.launchVMHost = { _, _ in
			try startServing(server)
			return ours
		}

		await #expect(throws: MachmanError.self) {
			try await rig.routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		}
		#expect(ours.ended == 1)
		// Before: unlinked while it still answered.
		#expect(FileManager.default.fileExists(atPath: rig.socketPath))
		#expect(rig.routing.hostedNames.isEmpty)
	}
}
