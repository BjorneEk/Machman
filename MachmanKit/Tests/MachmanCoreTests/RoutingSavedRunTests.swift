//
//  RoutingSavedRunTests.swift
//  MachmanTests
//
//  E27: a run saved as a new VM by an older vmhost (one that predates the socket following
//  the save) still answers on its original's socket. A restarted daemon adopts it under the
//  VM it serves, never the original, and never adopts a host as a VM it does not run.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingSavedRunTests {
	@MainActor
	private func makeRouting() throws -> (RoutingMachman, [String: String]) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "kept"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let tag = "\(getpid())-\(UInt32.random(in: 0..<99999))"
		let paths = [
			"alpha": TestEnvironment.scratch + "mm-a-\(tag).sock",
			"kept": TestEnvironment.scratch + "mm-k-\(tag).sock",
		]
		routing.socketPathForVM = { paths[$0] ?? TestEnvironment.scratch + "mm-x-\(tag).sock" }
		routing.hostProbeDeadline = .seconds(10)
		return (routing, paths)
	}

	@Test @MainActor func aRestartAdoptsAnOldSavedRunUnderItsNewName() async throws {
		let (routing, paths) = try makeRouting()
		let stub = StubMachman()
		stub.vms["kept"] = StubMachman.makeInfo("kept", state: .running)
		let server = MachmanServer(
			api: stub, socketPath: paths["alpha"]!, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		await routing.adoptExistingHosts()
		#expect(routing.hostedNames == ["kept"])   // before: ["alpha"]
		guard case .local = routing.residence(of: "alpha") else {
			Issue.record("alpha should be local"); return
		}
		do {
			try await routing.start(vm: "kept", options: StartOptions())
			Issue.record("expected already running")
		} catch let error as MachmanError {
			#expect(error.message.contains("already running"))
		}
		do {
			try await routing.start(vm: "alpha", options: StartOptions(force: true))
			Issue.record("expected a refusal")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("kept"))
		}
		let alpha = try await routing.vm(named: "alpha")
		#expect(alpha.state == .stopped)
	}

	@Test @MainActor func aSocketServingAnUnknownVMIsNeverAdoptedAsTheAskedOne() async throws {
		let (routing, paths) = try makeRouting()
		let stub = StubMachman()
		stub.vms["ghost"] = StubMachman.makeInfo("ghost", state: .running)
		let server = MachmanServer(
			api: stub, socketPath: paths["alpha"]!, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		await routing.adoptExistingHosts()
		#expect(routing.hostedNames.isEmpty)                      // before: ["alpha"]
		#expect(UDSListener.isLive(path: paths["alpha"]!))        // never unlinked
		let alpha = try await routing.vm(named: "alpha")
		#expect(alpha.state == .unknown)
		#expect(alpha.unresponsive == true)
	}
}
