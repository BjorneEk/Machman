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

	// A running vmhost for `vm`, answering on `vm`'s socket, that says it serves `folder` (as a
	// safe run's shadow with `shadow`).
	@MainActor
	private func orphan(_ rig: Rig, vm: String, folder: String?, shadow: Bool = false) throws
		-> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms[vm] = StubMachman.makeInfo(vm, state: .running)
		let server = MachmanServer(
			api: stub, socketPath: rig.runtime + "/vm-\(vm).sock", daemonVersion: "test-vmhost")
		server.helloHost = {
			RPCResults.Hello.Host(
				pid: getpid(), vm: vm, dataDir: rig.library, vmDir: folder, shadow: shadow)
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
		let listed = try await notResponding(rig, "beta")
		#expect(listed.state == .unknown)

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

	// `entry` as listed once the adoption a first listing sets off has failed: its vmhost
	// serves another name (Q40: a wait for that failure, never a wall-clock listing loop).
	@MainActor
	private func notResponding(_ rig: Rig, _ entry: String) async throws -> VMInfo {
		_ = try await rig.routing.vm(named: entry)
		#expect(await eventually { rig.routing.unadoptable.contains(entry) })
		let listed = try await rig.routing.vm(named: entry)
		#expect(listed.isUnresponsive)
		return listed
	}

	// The entry an orphan answers for lists Not responding (its vmhost serves another name)
	// and refuses a Start without spawning.
	@MainActor
	private func expectHeldByOrphan(_ rig: Rig, _ entry: String) async throws {
		let listed = try await notResponding(rig, entry)
		#expect(listed.state == .unknown)
		do {
			try await rig.routing.start(vm: entry, options: StartOptions(openWindow: false))
			Issue.record("a start went through while the orphan runs \(entry)")
		} catch let error as MachmanError {
			#expect(error.message == "\(entry) is not responding \u{2014} try again in a moment")
		}
	}

	// E11: a vmhost that missed its hello deadline at startup (a stalled main actor) was
	// logged and never asked again, so its renamed entry listed stopped and a Start booted a
	// second VZ on the same disks. It is asked again on the adoption timer until it answers.
	@Test(
		"""
		E11: an orphan that misses its first hello is placed when it answers a later one, and \
		its entry refuses a Start
		""")
	@MainActor func anOrphanThatMissesItsFirstHelloIsPlacedLater() async throws {
		let rig = try makeRig(["beta"])
		let (_, server) = try orphan(rig, vm: "alpha", folder: rig.library + "/beta")
		defer { server.stop() }
		let orphanSocket = rig.runtime + "/vm-alpha.sock"
		rig.routing.adoptionRetryInterval = .milliseconds(100)
		var asks = 0
		let answer = RPCResults.Hello.Host(
			pid: getpid(), vm: "alpha", dataDir: rig.library, vmDir: rig.library + "/beta",
			shadow: false)
		rig.routing.whomItServesForTesting = { _ in
			asks += 1
			return asks == 1 ? .silent : .served(answer)   // the first hello ran out its deadline
		}

		await rig.routing.identifyOrphanedHosts(in: rig.runtime)
		#expect(rig.routing.orphanSockets.isEmpty)
		// Before: never asked again.
		#expect(await eventually { rig.routing.orphanSockets == ["beta": orphanSocket] })
		try await expectHeldByOrphan(rig, "beta")
	}

	// E11: a safe run's vmhost whose VM folder was renamed while the agent was away answered
	// as a shadow, which the sweep dropped: its entry listed stopped while the run had its
	// unsafe disks attached. A shadow says the real VM's folder, and is placed by it.
	@Test("E11: a safe run's orphaned vmhost holds its renamed entry, which refuses a Start")
	@MainActor func aSafeRunsOrphanHoldsItsEntry() async throws {
		let rig = try makeRig(["beta"])
		let (_, server) = try orphan(
			rig, vm: "alpha", folder: rig.library + "/beta", shadow: true)
		defer { server.stop() }

		await rig.routing.identifyOrphanedHosts(in: rig.runtime)
		#expect(rig.routing.orphanSockets == ["beta": rig.runtime + "/vm-alpha.sock"])
		try await expectHeldByOrphan(rig, "beta")
	}

	// E11 (review F29): a vmhost from before hello said whom it serves answered like one
	// that never answered, so it was asked again — a connect and a hello every retry for its
	// whole life. It is asked once, logged, and left running.
	@Test("E11: a vmhost whose hello says nothing of whom it serves is asked once, not again")
	@MainActor func aVMHostTooOldToSayIsAskedOnce() async throws {
		let rig = try makeRig(["beta"])
		let (_, server) = try orphan(rig, vm: "alpha", folder: nil)
		defer { server.stop() }
		rig.routing.adoptionRetryInterval = .milliseconds(50)
		var asks = 0
		rig.routing.whomItServesForTesting = { _ in
			asks += 1
			return .unsaid
		}

		await rig.routing.identifyOrphanedHosts(in: rig.runtime)
		#expect(asks == 1)
		#expect(rig.routing.orphanQuestions.isEmpty)   // before: a retry timer for it
		try await Task.sleep(for: .milliseconds(200))   // four retry intervals
		#expect(asks == 1)
		#expect(rig.routing.orphanSockets.isEmpty)

		// The real ask tells a hello without its host from no hello at all.
		rig.routing.whomItServesForTesting = nil
		let old = MachmanServer(
			api: StubMachman(), socketPath: rig.runtime + "/vm-gamma.sock", daemonVersion: "1.0.11")
		try startServing(old)
		defer { old.stop() }
		await rig.routing.identifyOrphanedHosts(in: rig.runtime)
		#expect(rig.routing.orphanQuestions[rig.runtime + "/vm-gamma.sock"] == nil)
	}
}
