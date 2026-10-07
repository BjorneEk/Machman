//
//  SSHAddressDeadlineTests.swift
//  MachmanCoreTests
//
//  E57: only the readiness probe ever said "unreachable". A VM whose address never turned up
//  (a guest discovery can't place, no networking, a broken DHCP) read "SSH connecting" for
//  as long as it ran, with no reason. Discovery now gives the address phase the same bound
//  the probe has: once the settle window is spent, a VM with SSH set up reads unreachable
//  with the reason, discovery keeps looking, and an address found later moves it on. Driven
//  over Probes stand-ins on an adopted stub vmhost, at a test pace.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// The address the stand-in answers with, nil until the test sets one, and how often it was
// asked; sshd always answers.
@MainActor
private final class AddressSwitch {
	var address: String?
	private(set) var asks = 0

	var probes: SSHDiscovery.Probes {
		SSHDiscovery.Probes(
			address: { _ in await self.answer() },
			sshd: { _ in true })
	}

	private func answer() -> SSHDiscovery.Answer? {
		asks += 1
		return address.map { SSHDiscovery.Answer(address: $0, source: "dhcp") }
	}
}

// Holds one ask until the test lets it go; every other ask answers nil at once.
@MainActor
private final class HeldAsk {
	let held: Int
	private(set) var asks = 0
	private(set) var released = false
	private var waiter: CheckedContinuation<Void, Never>?

	init(held: Int) { self.held = held }

	var probes: SSHDiscovery.Probes {
		SSHDiscovery.Probes(
			address: { _ in await self.answer() },
			sshd: { _ in true })
	}

	func release() {
		released = true
		waiter?.resume()
		waiter = nil
	}

	private func answer() async -> SSHDiscovery.Answer? {
		asks += 1
		if asks == held, !released {
			await withCheckedContinuation { waiter = $0 }
		}
		return nil
	}
}

@MainActor
struct SSHAddressDeadlineTests {
	private static let mac = "aa:bb:cc:dd:ee:01"
	// Three quick asks stand in for the 24 five-second ones of the settle window.
	private static let pace = RoutingMachman.DiscoveryPace(
		fast: .milliseconds(10), fastTries: 3, slow: .milliseconds(30))

	private struct Rig {
		let routing: RoutingMachman
		let server: MachmanServer
		let host: RoutingMachman.HostedVM
	}

	// "alpha" adopted from a stub vmhost, its discovery left to the test. `ssh` is what the
	// vmhost serves: a guest user means SSH is set up there.
	private func adopt(ssh: SSHInfo?) async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			_ = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let path = TestEnvironment.socketPath("mm-e57", suffix: ".sock")
		routing.socketPathForVM = { _ in path }
		let stub = StubMachman()
		var alpha = StubMachman.makeInfo("alpha", state: .running)
		alpha.ssh = ssh
		stub.vms["alpha"] = alpha
		let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
		try startServing(server)
		// No MAC yet, so adoption starts no live discovery; the test starts its own.
		let identity = RoutingMachman.HostIdentity(id: UUID(), name: "alpha", socketPath: path)
		let client = try await routing.connectHost(identity: identity)
		let host = routing.adopt(identity: identity, client: client)
		host.identity.macInUse = Self.mac
		return Rig(routing: routing, server: server, host: host)
	}

	private func tearDown(_ rig: Rig) async {
		rig.host.sshDiscoveryTask?.cancel()
		rig.server.stop()
		await rig.host.client.disconnect()
	}

	@Test(
		"""
		E57: an address that never comes reads unreachable with the reason, and one found \
		later moves it on
		""")
	func noAddressReadsUnreachableThenRecovers() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let addresses = AddressSwitch()
		rig.routing.startSSHDiscovery(rig.host, probes: addresses.probes, pace: Self.pace)
		#expect(await eventually { rig.host.sshReach == .unreachable })
		var info = try await rig.routing.vm(named: "alpha")
		#expect(info.ssh?.reachability == .unreachable)
		#expect(info.ssh?.reachabilityDetail
			== "no address for \(Self.mac) in the DHCP leases or the ARP table")
		#expect(info.ssh?.address == nil)

		// Discovery kept looking: the address turns up and the probe answers.
		addresses.address = "192.168.64.20"
		#expect(await eventually { rig.host.sshReach == .ready })
		info = try await rig.routing.vm(named: "alpha")
		#expect(info.ssh?.address == "192.168.64.20")
		#expect(info.ssh?.reachability == .ready)
		#expect(info.ssh?.reachabilityDetail == nil)
		await tearDown(rig)
	}

	// Review F6: a restart (a refresh, a report, a reboot) cancels the pass whose last quick
	// ask is still out; that ask's late answer must not give the new pass's VM the old pass's
	// verdict.
	@Test("E57: a cancelled pass's late ask leaves no verdict on the pass after it")
	func aCancelledPassWritesNoVerdict() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let stand = HeldAsk(held: Self.pace.fastTries)
		rig.routing.startSSHDiscovery(rig.host, probes: stand.probes, pace: Self.pace)
		#expect(await eventually { stand.asks == Self.pace.fastTries })
		// The new pass asks at a pace that never gives up within the test.
		let patient = RoutingMachman.DiscoveryPace(
			fast: .milliseconds(10), fastTries: 100_000, slow: .seconds(1))
		rig.routing.startSSHDiscovery(rig.host, probes: stand.probes, pace: patient)
		#expect(await eventually { rig.host.sshReach == .waiting })
		stand.release()
		#expect(!(await eventually(timeout: .milliseconds(500)) {
			rig.host.sshReach == .unreachable
		}), "the cancelled pass wrote \(String(describing: rig.host.sshReachDetail))")
		await tearDown(rig)
	}

	// The address is a fact of any running VM, so discovery runs for every one; only a VM
	// with SSH set up has a connection to give up on.
	@Test("E57: a VM without SSH set up keeps looking without a verdict")
	func noSSHNoVerdict() async throws {
		let rig = try await adopt(ssh: nil)
		let addresses = AddressSwitch()
		rig.routing.startSSHDiscovery(rig.host, probes: addresses.probes, pace: Self.pace)
		// Well past the three quick asks.
		#expect(await eventually { addresses.asks >= 6 })
		#expect(rig.host.sshReach == .unknown)
		#expect(rig.host.sshReachDetail == nil)
		await tearDown(rig)
	}
}
