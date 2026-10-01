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
import MachmanFixtures
import MachmanTestSupport
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
		let socketPath = TestEnvironment.scratch
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
		let socketPath = TestEnvironment.scratch
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
		let socketPath = TestEnvironment.scratch
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
		let socketPath = TestEnvironment.scratch
			+ "mm-unadopted-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		routing.socketPathForVM = { _ in socketPath }
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-unadopted-accept")) { fd in
				close(fd)
			}

		do {
			try routing.requireStopped("alpha", "deleting it")
			Issue.record("expected invalidState while the socket is live")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("still running"))
		}

		// SIGKILL leftover: the file exists but nothing listens — no refusal.
		listener.simulateKillForTesting()
		#expect(throws: Never.self) {
			try routing.requireStopped("alpha", "deleting it")
		}
		unlink(socketPath)
	}

	// D1's follow-up: every whole-VM edit — not only delete — must refuse while a vmhost the
	// daemon never adopted answers on the VM's socket; each one moves or rewrites files that
	// host is serving.
	@Test @MainActor func wholeVMEditsRefuseWhileAnUnadoptedVMHostOwnsTheSocket() async throws {
		let routing = try makeRouting()
		let socketPath = TestEnvironment.scratch
			+ "mm-unadopted2-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		routing.socketPathForVM = { _ in socketPath }
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-unadopted2-accept")) { fd in
				close(fd)
			}
		defer { listener.shutdown() }

		let ops: [(String, () async throws -> Void)] = [
			("rename", { try await routing.renameVM(named: "alpha", to: "x") }),
			("copy", { _ = try await routing.copyVM(
				vm: "alpha", newName: nil, diskIDs: nil, regenerateMAC: true) }),
			("regenerateMAC", { _ = try await routing.regenerateMAC(vm: "alpha") }),
			("resizeDisk", { _ = try await routing.resizeDisk(
				vm: "alpha", diskID: "storage:disk", sizeBytes: 1) }),
			("renameDisk", { _ = try await routing.renameDisk(
				vm: "alpha", diskID: "storage:disk", newName: "y") }),
			("removeDisk", { try await routing.removeDisk(vm: "alpha", diskID: "storage:disk") }),
			("promoteDisk", { _ = try await routing.promoteDisk(
				vm: "alpha", diskID: "storage:disk") }),
			("consoleAdd", { try await routing.addConsolePort(vm: "alpha") }),
			("uartAdd", { try await routing.addUartPort(vm: "alpha") }),
			("renameKernelFile", { _ = try await routing.renameKernelFile(
				vm: "alpha", path: "/k", tag: "t") }),
			("installStart", { try await routing.startMacInstall(vm: "alpha", source: .latest) }),
		]
		for (label, op) in ops {
			do {
				try await op()
				Issue.record("\(label): expected invalidState while a vmhost owns the socket")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState, "\(label) carried \(error.code)")
				#expect(error.message.contains("still running"), "\(label): \(error.message)")
			} catch {
				Issue.record("\(label): \(error)")
			}
		}
	}

	// A proxied edit must not land on the daemon's config copy under a live unadopted host
	// either (the host's own saves would revert it).
	@Test @MainActor func proxiedCallsRefuseAnUnadoptedVMHost() async throws {
		let routing = try makeRouting()
		let socketPath = TestEnvironment.scratch
			+ "mm-unadopted3-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		routing.socketPathForVM = { _ in socketPath }
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-unadopted3-accept")) { fd in
				close(fd)
			}
		defer { listener.shutdown() }

		do {
			try await routing.setHardware(
				vm: "alpha", cpuCount: 3, memoryBytes: nil, nestedVirtualization: nil)
			Issue.record("expected invalidState while a vmhost owns the socket")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
		}
		#expect(try await routing.vm(named: "alpha").cpuCount == 2)
	}

	// D6: the stale-socket sweep also matches the serial data-plane sockets (tty-*.sock) a
	// crashed vmhost leaves beside its control socket — and only ever removes dead ones.
	@Test @MainActor func socketPruneCoversSerialSockets() throws {
		let routing = try makeRouting()
		let fm = FileManager.default
		let dir = TestEnvironment.scratch
			+ "mm-prune-\(getpid())-\(UInt32.random(in: 0..<99999))"
		try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? fm.removeItem(atPath: dir) }
		fm.createFile(atPath: dir + "/vm-dead0000.sock", contents: nil)
		fm.createFile(atPath: dir + "/tty-dead0000.sock", contents: nil)
		fm.createFile(atPath: dir + "/machman.sock", contents: nil)  // the daemon's own
		let livePath = dir + "/tty-live0000.sock"
		let listener = try UDSListener(
			path: livePath, queue: DispatchQueue(label: "mm-prune-accept")) { fd in
				close(fd)
			}

		routing.pruneDeadHostSockets(dir: dir)
		#expect(!fm.fileExists(atPath: dir + "/vm-dead0000.sock"))
		#expect(!fm.fileExists(atPath: dir + "/tty-dead0000.sock"))
		#expect(fm.fileExists(atPath: dir + "/machman.sock"))
		#expect(fm.fileExists(atPath: livePath))
		listener.simulateKillForTesting()
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
