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

// An answer the test moves, or none; how often it was asked.
@MainActor
private final class MovingAnswer {
	var address: String? = "192.168.64.20"
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

// The hints a VM's reports taught, as the test changes them; how often they were read.
@MainActor
private final class Taught {
	var hints: SSHDiscovery.Hints
	private(set) var asks = 0

	init(_ hints: SSHDiscovery.Hints) { self.hints = hints }

	func ask() -> SSHDiscovery.Hints {
		asks += 1
		return hints
	}
}

// "alpha"'s config where a probe reads it, saved as its vmhost saves what a report taught.
// VMTestDir only mints it (the redirect is sync-only); the library is the test's own.
@MainActor
private final class TaughtConfig {
	let library = TestEnvironment.scratch + "library-\(UUID().uuidString)"
	private let config: VMConfig

	init() throws {
		config = try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			return try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
		}
	}

	func save(clientID: String, address: String) throws {
		var ssh = SSHConfig()
		ssh.dhcpClientID = clientID
		ssh.lastAddress = address
		config.ssh = ssh
		let folder = library + "/alpha"
		try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		try JSONEncoder().encode(config)
			.write(to: URL(fileURLWithPath: folder + "/config"), options: .atomic)
	}

	func remove() {
		try? FileManager.default.removeItem(atPath: library)
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

	// Another running VM beside the rig's, adopted from a stub vmhost of its own.
	private func adoptAnother(
		_ rig: Rig, _ name: String
	) async throws -> (host: RoutingMachman.HostedVM, server: MachmanServer) {
		let path = TestEnvironment.socketPath("mm-e57b", suffix: ".sock")
		let stub = StubMachman()
		stub.vms[name] = StubMachman.makeInfo(name, state: .running)
		let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(id: UUID(), name: name, socketPath: path)
		let client = try await rig.routing.connectHost(identity: identity)
		return (rig.routing.adopt(identity: identity, client: client), server)
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

	// Review F5: an answer is asked again when the next report arrives (since F12 every
	// answer, not only one resting on what a report taught), and a lookup that now lands
	// elsewhere starts discovery over. One that lands where it was, or finds nothing (an ARP
	// entry aged out under a guest no lease or report names), leaves readiness alone (F19).
	@Test("E56: a report that moves a hint-sourced answer starts discovery over")
	func aReportMovesAHintSourcedAnswer() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let stand = MovingAnswer()
		rig.routing.startSSHDiscovery(rig.host, probes: stand.probes, pace: Self.pace)
		#expect(await eventually { rig.host.sshReach == .ready })
		stand.address = "192.168.64.21"
		rig.routing.sshReportArrived(rig.host, probes: stand.probes)
		#expect(await eventually {
			rig.host.sshAnswer?.address == "192.168.64.21" && rig.host.sshReach == .ready
		})

		// The lookup lands where it was: no restart, so readiness doesn't blink.
		let since = rig.host.sshReadySince
		let asked = stand.asks
		rig.routing.sshReportArrived(rig.host, probes: stand.probes)
		#expect(await eventually { stand.asks == asked + 1 })
		#expect(!(await eventually(timeout: .milliseconds(500)) {
			rig.host.sshReadySince != since
		}), "the report restarted discovery")

		// The lookup finds nothing now: the VM is still where it was.
		stand.address = nil
		rig.routing.sshReportArrived(rig.host, probes: stand.probes)
		#expect(await eventually { stand.asks >= asked + 2 })
		#expect(!(await eventually(timeout: .milliseconds(500)) {
			rig.host.sshReadySince != since
		}), "a lookup that found nothing restarted discovery")
		#expect(rig.host.sshAnswer?.address == "192.168.64.21")
		await tearDown(rig)
	}

	// Review F8: Duplicate, Guest Setup in the copy, the reboot that renews its machine id. The
	// copy's config still holds the source's client id, whose lease names the address the
	// running source answers: the copy keeps looking, and its own report's id moves it to its
	// own lease.
	@Test("E56: a copy's stale client id waits while its source answers that address")
	func aStaleHintWaitsWhileTheSourceAnswers() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let (source, sourceServer) = try await adoptAnother(rig, "source")
		source.sshAnswer = SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp")
		let leases = """
			{
				ip_address=192.168.64.21
				hw_address=ff,1:2:3
				identifier=ff,1:2:3
				lease=0x66aa0001
			}
			{
				ip_address=192.168.64.33
				hw_address=ff,4:5:6
				identifier=ff,4:5:6
				lease=0x66aa0002
			}
			"""
		let taught = Taught(SSHDiscovery.Hints(clientID: "ff,1:2:3"))
		let probes = SSHDiscovery.Probes(
			address: { lookup in
				SSHDiscovery.discover(
					mac: lookup.mac, leasesText: leases, arpText: "",
					hints: await taught.ask(), interfaces: [], taken: lookup.taken)
			},
			sshd: { _ in true })
		let patient = RoutingMachman.DiscoveryPace(
			fast: .milliseconds(10), fastTries: 100_000, slow: .seconds(1))
		rig.routing.startSSHDiscovery(rig.host, probes: probes, pace: patient)
		#expect(await eventually { taught.asks >= 5 })
		#expect(rig.host.sshAnswer == nil, "took \(String(describing: rig.host.sshAnswer))")
		taught.hints = SSHDiscovery.Hints(clientID: "ff,4:5:6")   // the copy's own report
		rig.routing.sshReportArrived(rig.host, probes: probes)
		#expect(await eventually { rig.host.sshAnswer?.address == "192.168.64.33" })
		sourceServer.stop()
		await source.client.disconnect()
		await tearDown(rig)
	}

	// A copy's leases after the reboot that renewed its client id: the source's under the id
	// both shared before, the copy's under its own.
	private static let copyLeases = """
		{
			ip_address=192.168.64.17
			hw_address=ff,1:2:3
			identifier=ff,1:2:3
			lease=0x66aa0001
		}
		{
			ip_address=192.168.64.21
			hw_address=ff,4:5:6
			identifier=ff,4:5:6
			lease=0x66aa0002
		}
		"""

	// Discovery as discoverLive runs it, over the copy's leases (while they are live), an ARP
	// table and the hints its config on disk holds.
	private func copyProbes(_ config: TaughtConfig, arp: String) -> SSHDiscovery.Probes {
		let library = config.library
		let leases = Self.copyLeases
		return SSHDiscovery.Probes(
			address: { lookup in
				SSHDiscovery.discover(
					mac: lookup.mac, leasesText: leases, arpText: arp,
					hints: SSHDiscovery.hints(vm: lookup.vm, library: library), interfaces: [],
					now: Date(timeIntervalSince1970: TimeInterval(0x66aa0000)),
					taken: lookup.taken)
			},
			sshd: { _ in true })
	}

	// Review F8's flow end to end, through the config on disk: the copy's config still holds
	// its source's client id, so the first pass lands on the source's lease; the copy's boot
	// report teaches its own id, which moves it to its own lease.
	@Test("E56: a copy's boot report moves it off its source's lease")
	func aCopysBootReportMovesItOffItsSourcesLease() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let config = try TaughtConfig()
		try config.save(clientID: "ff,1:2:3", address: "192.168.64.17")
		let probes = copyProbes(config, arp: "")
		rig.routing.startSSHDiscovery(rig.host, probes: probes, pace: Self.pace)
		#expect(await eventually {
			rig.host.sshAnswer?.address == "192.168.64.17" && rig.host.sshReach == .ready
		})
		try config.save(clientID: "ff,4:5:6", address: "192.168.64.21")
		rig.routing.sshReportArrived(rig.host, probes: probes)
		#expect(await eventually {
			rig.host.sshAnswer == SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp")
				&& rig.host.sshReach == .ready
		})
		config.remove()
		await tearDown(rig)
	}

	// Review F12: the Mac's ARP table still names the source's address under the copy's MAC
	// (the copy held it last run), so the first pass answers from ARP; the copy's boot report
	// teaches its own client id, under which the source's live lease shows the entry stale.
	@Test("E56: a report moves an answer off a stale ARP entry")
	func aReportMovesAnAnswerOffAStaleARPEntry() async throws {
		let rig = try await adopt(ssh: SSHInfo(configured: true, guestUser: "admin"))
		let config = try TaughtConfig()
		try config.save(clientID: "ff,1:2:3", address: "192.168.64.17")
		let probes = copyProbes(
			config, arp: "? (192.168.64.17) at aa:bb:cc:dd:ee:1 on bridge100 [ethernet]")
		rig.routing.startSSHDiscovery(rig.host, probes: probes, pace: Self.pace)
		#expect(await eventually {
			rig.host.sshAnswer == SSHDiscovery.Answer(address: "192.168.64.17", source: "arp")
				&& rig.host.sshReach == .ready
		})
		try config.save(clientID: "ff,4:5:6", address: "192.168.64.21")
		rig.routing.sshReportArrived(rig.host, probes: probes)
		#expect(await eventually {
			rig.host.sshAnswer == SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp")
				&& rig.host.sshReach == .ready
		})
		config.remove()
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
