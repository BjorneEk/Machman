//
//  RoutingOrphanTests.swift
//  MachmanCoreTests
//
//  E11: a running VM's folder renamed in Finder while no daemon watched left its vmhost on
//  the old name's socket, which adoption — asking only the current names' sockets — never
//  asked: a VM no client could see, stop or adopt, its renamed entry listed stopped, and a
//  Start booted a second VZ on the same disks. A vmhost says whom it serves now (hello's
//  host, PR21): the startup sweep asks every socket no VM accounts for, and adoption never
//  takes a vmhost serving another folder for the VM whose name it answers to.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingOrphanTests {
	private struct Rig {
		let routing: RoutingMachman
		let library: String   // the VMs' folders, as the vmhosts name them
		let runtime: String   // the vmhosts' sockets, vm-<name>.sock
	}

	// The library holds `names`; each has its folder in a scratch library the router matches
	// vmhosts' folders in (the VMs' configs live in the test's redirected one).
	@MainActor
	private func makeRig(_ names: [String]) throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		let fm = FileManager.default
		let library = TestEnvironment.scratch + "lib-\(UUID().uuidString)"
		for name in names {
			try fm.createDirectory(atPath: library + "/" + name, withIntermediateDirectories: true)
		}
		let runtime = TestEnvironment.socketPath("mm-orph", suffix: "")
		try fm.createDirectory(atPath: runtime, withIntermediateDirectories: true)
		routing.socketPathForVM = { runtime + "/vm-\($0).sock" }
		routing.libraryDir = { library }
		routing.locateVMHost = {
			Issue.record("a start went on to spawn a vmhost")
			return nil
		}
		routing.hostProbeDeadline = .seconds(10)
		return Rig(routing: routing, library: library, runtime: runtime)
	}

	// A running vmhost for `vm`, answering on `vm`'s socket, that says it serves `folder`.
	@MainActor
	private func orphan(_ rig: Rig, vm: String, folder: String?) throws
		-> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms[vm] = StubMachman.makeInfo(vm, state: .running)
		let server = MachmanServer(
			api: stub, socketPath: rig.runtime + "/vm-\(vm).sock", daemonVersion: "test-vmhost")
		server.helloHost = {
			RPCResults.Hello.Host(
				pid: getpid(), vm: vm, dataDir: rig.library, vmDir: folder, shadow: false)
		}
		try startServing(server)
		return (stub, server)
	}

	@Test(
		"""
		E11: a vmhost whose VM folder was renamed lists its new entry Not responding and never \
		starts a second VZ
		""")
	@MainActor func aRenamedFoldersVMHostIsFoundAtStartup() async throws {
		let rig = try makeRig(["beta"])   // alpha's folder, renamed beta while it ran
		let (_, server) = try orphan(rig, vm: "alpha", folder: rig.library + "/beta")
		defer { server.stop() }
		let orphanSocket = rig.runtime + "/vm-alpha.sock"

		await rig.routing.identifyOrphanedHosts(in: rig.runtime)
		#expect(rig.routing.orphanSockets == ["beta": orphanSocket])
		// Before: listed stopped. Its vmhost can't be adopted as beta (it serves alpha).
		var listed: VMInfo?
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(20))
		while clock.now < deadline {
			let info = try await rig.routing.vm(named: "beta")
			if info.isUnresponsive {
				listed = info
				break
			}
			try await Task.sleep(for: .milliseconds(100))
		}
		#expect(listed?.state == .unknown)

		// Before: a second vmhost was spawned on beta's disks.
		do {
			try await rig.routing.start(vm: "beta", options: StartOptions(openWindow: false))
			Issue.record("a start went through while the orphan runs beta")
		} catch let error as MachmanError {
			#expect(error.message == "beta is not responding \u{2014} try again in a moment")
		}

		var ended: [String] = []
		rig.routing.endSocketHolder = { path in
			ended.append(path)
			server.stop()
			return true
		}
		try await rig.routing.endProcess(vm: "beta")
		#expect(ended == [orphanSocket])
		#expect(try await rig.routing.vm(named: "beta").state == .stopped)
	}

	@Test("E11: a VM renamed to an orphan's old name is never adopted as that orphan")
	@MainActor func aVMRenamedToAnOrphansNameIsNeverAdoptedAsIt() async throws {
		let rig = try makeRig(["alpha"])   // another VM, renamed alpha in Finder
		let trash = TestEnvironment.scratch + "trash-\(UUID().uuidString)/alpha"
		try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
		let (stub, server) = try orphan(rig, vm: "alpha", folder: trash)
		defer { server.stop() }

		// Before: adopted, and its saves landed in the other VM's folder.
		await #expect(throws: MachmanError.self) {
			try await rig.routing.adoptLiveHost("alpha")
		}
		#expect(rig.routing.hostForTesting("alpha") == nil)
		#expect(!stub.calls.contains("vm"))
	}

	@Test("E11: a rename to a name whose vmhost socket still answers is refused")
	@MainActor func aRenameToAnOrphansNameIsRefused() async throws {
		let rig = try makeRig(["gamma"])
		let (_, server) = try orphan(rig, vm: "alpha", folder: nil)
		defer { server.stop() }
		do {
			try await rig.routing.renameVM(named: "gamma", to: "alpha")
			Issue.record("renamed onto a running vmhost's name")
		} catch let error as MachmanError {
			#expect(error.message
				== "\u{201C}alpha\u{201D} is still in use by a running Machman VM \u{2014} "
					+ "choose another name")
		}
	}

	// A Finder rename of the running alpha to beta, then another folder renamed alpha: the
	// orphan answers on alpha's socket and serves beta's folder. Adoption keyed a vmhost that
	// didn't serve the VM it was asked for by the VM it said it served (E27) — alpha again,
	// whose folder it doesn't serve.
	@Test("E11: an orphan is never re-keyed as a VM whose folder it doesn't serve")
	@MainActor func anOrphanIsNeverRekeyedAsAnotherFoldersVM() async throws {
		let rig = try makeRig(["alpha", "beta"])
		let (_, server) = try orphan(rig, vm: "alpha", folder: rig.library + "/beta")
		defer { server.stop() }

		await #expect(throws: MachmanError.self) { try await rig.routing.adoptLiveHost("alpha") }
		#expect(rig.routing.orphanSockets == ["beta": rig.runtime + "/vm-alpha.sock"])
		await #expect(throws: MachmanError.self) { try await rig.routing.adoptLiveHost("beta") }
		#expect(rig.routing.hostForTesting("alpha") == nil)
		#expect(rig.routing.hostForTesting("beta") == nil)
	}
}
