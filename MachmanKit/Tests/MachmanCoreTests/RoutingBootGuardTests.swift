//
//  RoutingBootGuardTests.swift
//  MachmanTests
//
//  E37: a vmhost the daemon hasn't adopted — a launch-agent start that bound after startup
//  adoption, a host that missed hello — escaped the start guards, so a second VM could boot
//  on its disk image or its MAC. A start now adopts every such host first, and counts one it
//  can't adopt from the daemon's config copy. Both VMs name one scratch image, so nothing
//  async depends on the redirected library.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

// Accepts and holds every connection without ever answering: a vmhost whose main actor is
// wedged, so it never answers hello.
private final class SilentHost: @unchecked Sendable {
	private let lock = NSLock()
	private var held: [Int32] = []
	private var listener: UDSListener!

	init(path: String) throws {
		listener = try UDSListener(path: path, queue: DispatchQueue(label: "mm-silent-host")) {
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

struct RoutingBootGuardTests {
	private struct Rig {
		let routing: RoutingMachman
		let betaSocket: String
		let image: String
	}

	// alpha and beta, sharing one external image or one MAC; beta's vmhost answers on
	// `betaSocket`, which nobody has adopted.
	@MainActor
	private func makeRig(shareDisk: Bool, mac: String? = nil) throws -> Rig {
		let image = TestEnvironment.scratch + "shared-\(UUID().uuidString).img"
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				if let mac { cfg.macAddress = mac }
				if shareDisk {
					try cfg.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
				}
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		let betaSocket = TestEnvironment.socketPath("mm-guard-b")
		routing.socketPathForVM = { $0 == "beta" ? betaSocket : betaSocket + ".none-" + $0 }
		routing.hostProbeDeadline = .seconds(10)
		return Rig(routing: routing, betaSocket: betaSocket, image: image)
	}

	@MainActor
	private func serveBeta(_ rig: Rig) throws -> MachmanServer {
		let stub = StubMachman()
		stub.vms["beta"] = StubMachman.makeInfo("beta", state: .running)
		let server = MachmanServer(api: stub, socketPath: rig.betaSocket, daemonVersion: "test")
		try startServing(server)
		return server
	}

	private func refusal(_ routing: RoutingMachman, force: Bool) async throws -> MachmanError {
		do {
			try await routing.start(vm: "alpha", options: StartOptions(force: force))
		} catch let error as MachmanError {
			return error
		}
		throw MachmanError(code: .internalError, message: "the start went through")
	}

	@Test @MainActor func aStartAdoptsAnUnadoptedSharerFirst() async throws {
		let rig = try makeRig(shareDisk: true)
		let server = try serveBeta(rig)
		defer { server.stop() }

		let error = try await refusal(rig.routing, force: true)
		// Before: past the guard, failing at the spawn ("… reinstall Machman").
		let file = (rig.image as NSString).lastPathComponent
		#expect(error.code == .invalidState)
		#expect(error.message
			== "beta is running with \(file) attached — stop beta before starting alpha")
		#expect(rig.routing.hostedNames == ["beta"])
	}

	@Test @MainActor func aSharerThatCantBeAdoptedStillCounts() async throws {
		let rig = try makeRig(shareDisk: true)
		let listener = try UDSListener(
			path: rig.betaSocket, queue: DispatchQueue(label: "mm-guard-accept")) { fd in
				close(fd)
			}
		defer { listener.shutdown() }

		let error = try await refusal(rig.routing, force: true)
		let file = (rig.image as NSString).lastPathComponent
		#expect(error.message
			== "beta may still have \(file) attached — stop beta before starting alpha")
		#expect(rig.routing.hostedNames.isEmpty)
	}

	// Review F8: a vmhost that never answers hello, already marked unadoptable, was asked
	// again by every start of any other VM — its hello deadline, under the start claim.
	@Test @MainActor func aKnownUnadoptableHostCostsAStartNothing() async throws {
		let rig = try makeRig(shareDisk: false)
		rig.routing.helloDeadline = .seconds(10)
		let silent = try SilentHost(path: rig.betaSocket)
		defer { silent.close() }
		rig.routing.unadoptable.insert("beta")   // an earlier adoption failed

		let clock = ContinuousClock()
		let started = clock.now
		let error = try await refusal(rig.routing, force: false)
		#expect(error.message.contains("reinstall Machman"))   // on to the spawn
		#expect(clock.now - started < .seconds(5))   // before: the 10 s hello first
		#expect(rig.routing.adoptionAttempts == 0)
	}

	@Test @MainActor func anUnadoptedVMsMACCounts() async throws {
		let mac = "aa:bb:cc:66:00:01"
		let rig = try makeRig(shareDisk: false, mac: mac)
		let server = try serveBeta(rig)
		defer { server.stop() }

		let error = try await refusal(rig.routing, force: false)
		#expect(error.code == .macConflict)
		#expect(error.message.contains("\u{201C}beta\u{201D}"))
	}
}
