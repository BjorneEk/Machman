//
//  RoutingProbeAdoptTests.swift
//  MachmanTests
//
//  The router's probe-and-adopt path (start() meeting a socket a launchd-started vmhost
//  already owns), exercised through the internal seam with an injected socket path — no VZ,
//  no spawn, no dependency on the global runtime dir at async time. Config/registry setup
//  happens inside the redirected-dir lock (synchronous), same pattern as MacConflictTests.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingProbeAdoptTests {
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

	@Test @MainActor func startAdoptsALiveHostAndForwardsTheStart() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-probe-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openWindow: false))
		#expect(handled)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.vms["alpha"]?.state == .running)   // the start reached the host
	}

	@Test @MainActor func adoptOfARunningHostToleratesInvalidState() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-probe2-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		// The host refuses the forwarded start (already running); the probe still adopts
		// and honors openWindow so the caller gets what they asked for.
		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openWindow: true))
		#expect(handled)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.windowOpens == 1)
	}

	@Test @MainActor func deadSocketIsReclaimedAndNotAdopted() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-dead-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		FileManager.default.createFile(atPath: socketPath, contents: nil)

		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions())
		#expect(!handled)                                              // caller spawns fresh
		#expect(!FileManager.default.fileExists(atPath: socketPath))   // leftover reclaimed
		#expect(routing.hostedNames.isEmpty)
	}

	// D1: delete's running-check must not stop at the in-memory hosted map — a vmhost the
	// daemon never adopted (launch-agent start, socket appeared after adoption ran) still
	// owns the VM's directory. A live socket refuses; a dead leftover file does not.
	@Test @MainActor func deleteRefusesWhileAnUnadoptedVMHostOwnsTheSocket() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-unadopted-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-unadopted-accept")) { fd in
				close(fd)
			}

		do {
			try routing.refuseUnadoptedHost("alpha", "deleting it", socketPath: socketPath)
			Issue.record("expected invalidState while the socket is live")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("still running"))
		}

		// SIGKILL leftover: the file exists but nothing listens — no refusal.
		listener.simulateKillForTesting()
		#expect(throws: Never.self) {
			try routing.refuseUnadoptedHost("alpha", "deleting it", socketPath: socketPath)
		}
		unlink(socketPath)
	}

	// D1's second blind spot: the startup leftover sweep must skip VMs whose socket answers
	// even though the hosted map has never heard of them. Covers all three leftovers it
	// removes: the served payload, a crash-abandoned disk-import staging file (D3), and a
	// crash-abandoned downloaded restore image (D4).
	@Test @MainActor func leftoverSweepSparesLiveUnadoptedHosts() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			let routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			let payload = GuestInstallerWriter.payloadDirectory(
				named: GuestSetupInstallerInfo.directoryName, for: cfg)
			try FileManager.default.createDirectory(
				at: payload, withIntermediateDirectories: true)
			let staging = cfg.vmDirPath() + "/" + DiskImport.stagingPrefix + "leftover"
			try Data("partial".utf8).write(to: URL(fileURLWithPath: staging))
			let ipsw = cfg.configFilePath(file: MacInstaller.restoreImageFileName)
			try Data("ipsw".utf8).write(to: URL(fileURLWithPath: ipsw))

			routing.sweepStoppedVMLeftovers(isSocketLive: { _ in true })
			#expect(FileManager.default.fileExists(atPath: payload.path))
			#expect(FileManager.default.fileExists(atPath: staging))
			#expect(FileManager.default.fileExists(atPath: ipsw))

			routing.sweepStoppedVMLeftovers(isSocketLive: { _ in false })
			#expect(!FileManager.default.fileExists(atPath: payload.path))
			#expect(!FileManager.default.fileExists(atPath: staging))
			#expect(!FileManager.default.fileExists(atPath: ipsw))
		}
	}
}
