//
//  SSHDiscoveryTests.swift
//  MachmanTests
//
//  Address discovery parsers (string-input only — never the real /var/db or arp): the
//  bootpd lease format with its leading-zero-stripped MACs, the arp table, the TCP
//  probe against an in-test listener, and the probe-gated orchestration.
//

// (1.0.6) The gateway derivation the BSD setup guide and the reverse-SSH hint both show
// before any guest has reported anything.
import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct SSHDiscoveryTests {

	// bootpd strips leading zeros per octet; VZMACAddress strings don't.
	private let leases = """
		{
			name=debby
			ip_address=192.168.64.5
			hw_address=1,a6:83:e7:12:3:45
			identifier=1,a6:83:e7:12:3:45
			lease=0x66aa0001
		}
		{
			name=debby
			ip_address=192.168.64.9
			hw_address=1,a6:83:e7:12:3:45
			lease=0x66aa9999
		}
		{
			name=other
			ip_address=192.168.64.7
			hw_address=1,3a:1:2:3:4:5
			lease=0x66aa5555
		}
		"""

	@Test func macNormalizationBridgesTheFormats() {
		#expect(SSHDiscovery.normalizedMAC("A6:83:E7:12:03:45")
			== SSHDiscovery.normalizedMAC("a6:83:e7:12:3:45"))
		#expect(SSHDiscovery.normalizedMAC("00:03:93:00:00:01") == "0:3:93:0:0:1")
	}

	@Test func leaseLookupPicksTheNewestMatch() {
		// The full-form MAC (what VMConfig persists) matches the stripped lease entries,
		// and the higher lease timestamp wins over file order.
		#expect(SSHDiscovery.leaseIP(for: "A6:83:E7:12:03:45", inLeasesText: leases)
			== "192.168.64.9")
		#expect(SSHDiscovery.leaseIP(for: "3A:01:02:03:04:05", inLeasesText: leases)
			== "192.168.64.7")
		#expect(SSHDiscovery.leaseIP(for: "aa:bb:cc:dd:ee:ff", inLeasesText: leases) == nil)
	}

	@Test func arpLookupSkipsIncompleteEntries() {
		let arp = """
			? (192.168.64.1) at (incomplete) on bridge100 ifscope [ethernet]
			? (192.168.64.9) at a6:83:e7:12:3:45 on bridge100 ifscope [ethernet]
			? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
			"""
		#expect(SSHDiscovery.arpIP(for: "A6:83:E7:12:03:45", inARPOutput: arp)
			== "192.168.64.9")
		#expect(SSHDiscovery.arpIP(for: "de:ad:be:ef:00:01", inARPOutput: arp) == nil)
	}

	@Test func probeAnswersForARealListenerOnly() async throws {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		defer { close(fd) }
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = 0
		addr.sin_addr.s_addr = inet_addr("127.0.0.1")
		let bindResult = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		try #require(bindResult == 0)
		try #require(listen(fd, 1) == 0)
		var bound = sockaddr_in()
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		_ = withUnsafeMutablePointer(to: &bound) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(fd, $0, &len)
			}
		}
		let port = UInt16(bigEndian: bound.sin_port)
		#expect(await SSHDiscovery.probeTCP(host: "127.0.0.1", port: port, timeout: 2))
		// Port 1 is root-only and unbound — refused fast.
		#expect(!(await SSHDiscovery.probeTCP(host: "127.0.0.1", port: 1, timeout: 1)))
	}

	// No liveness gate (a guest without sshd still has an address worth showing):
	// the lease wins, ARP is the fallback, nothing found → retry.
	@Test func orchestrationPrefersLeasesThenARP() {
		let arp = "? (192.168.64.20) at a6:83:e7:12:3:45 on bridge100 [ethernet]"
		#expect(SSHDiscovery.discover(
			mac: "A6:83:E7:12:03:45", leasesText: leases, arpText: arp)
			== SSHDiscovery.Answer(address: "192.168.64.9", source: "dhcp"))
		#expect(SSHDiscovery.discover(
			mac: "A6:83:E7:12:03:45", leasesText: nil, arpText: arp)
			== SSHDiscovery.Answer(address: "192.168.64.20", source: "arp"))
		#expect(SSHDiscovery.discover(
			mac: "de:ad:be:ef:00:01", leasesText: leases, arpText: arp) == nil)
	}

	// E56: bootpd keeps a client that sends a DHCP client id (RFC 4361: type ff, IAID and
	// DUID — systemd-networkd's default) under that id, so its lease names no MAC: the lab's
	// Debian guests sat at "SSH waiting" because only ARP could find them.
	private let clientIDLeases = """
		{
			name=debian
			ip_address=192.168.64.17
			hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d
			identifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d
			lease=0x66aa0001
		}
		{
			ip_address=192.168.64.21
			hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d
			identifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d
			lease=0x66aa9999
		}
		{
			name=other
			ip_address=192.168.64.30
			hw_address=1,3a:1:2:3:4:5
			identifier=1,3a:1:2:3:4:5
			lease=0x66aa5555
		}
		"""
	private let debianID = "ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d"
	private let vmMAC = "5e:2c:7a:10:44:01"

	private func vmnet() throws -> [SSHDiscovery.IPv4Interface] {
		[try #require(SSHDiscovery.IPv4Interface("192.168.64.1", mask: "255.255.255.0"))]
	}

	@Test("E56: a lease kept under a DHCP client id is found by that id, the newest first")
	func clientIDLeaseLookup() {
		let table = SSHDiscovery.leases(inText: clientIDLeases)
		#expect(SSHDiscovery.leaseIP(forClientID: debianID, in: table) == "192.168.64.21")
		// Full-form octets match bootpd's stripped ones, as MACs do.
		#expect(SSHDiscovery.leaseIP(
			forClientID: "FF,F1:F5:DD:7F:00:02:00:00:AB:11:B5:33:C7:D7:F3:C8:58:7D", in: table)
			== "192.168.64.21")
		#expect(SSHDiscovery.leaseIP(for: vmMAC, in: table) == nil)   // no MAC in the lease
		#expect(SSHDiscovery.clientID(holding: "192.168.64.17", inLeasesText: clientIDLeases)
			== debianID)
		// A MAC lease teaches no client id; nor does an address no lease holds.
		#expect(SSHDiscovery.clientID(holding: "192.168.64.30", inLeasesText: clientIDLeases)
			== nil)
		#expect(SSHDiscovery.clientID(holding: "192.168.64.99", inLeasesText: clientIDLeases)
			== nil)
	}

	@Test("E56: discovery finds a client-id guest by the client id its config keeps")
	func clientIDGuestIsFound() throws {
		let net = try vmnet()
		let hints = SSHDiscovery.Hints(clientID: debianID, reported: "192.168.64.17")
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: clientIDLeases, arpText: "", hints: hints,
			interfaces: net)
			== SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp"))
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: clientIDLeases, arpText: "", interfaces: net) == nil)
	}

	@Test(
		"""
		E56: a reported address answers only on this Mac's subnets and while no live lease names \
		another client
		""")
	func reportedAddressIsChecked() throws {
		let net = try vmnet()
		let beforeExpiry = Date(timeIntervalSince1970: TimeInterval(0x66aa0000))
		let afterExpiry = Date(timeIntervalSince1970: TimeInterval(0x66ab0000))
		func answer(_ reported: String, at now: Date) -> SSHDiscovery.Answer? {
			SSHDiscovery.discover(
				mac: vmMAC, leasesText: clientIDLeases, arpText: "",
				hints: SSHDiscovery.Hints(reported: reported), interfaces: net, now: now)
		}
		// A static address no lease names.
		#expect(answer("192.168.64.40", at: beforeExpiry)
			== SSHDiscovery.Answer(address: "192.168.64.40", source: "report"))
		// Another client's live lease, then the same lease run out.
		#expect(answer("192.168.64.30", at: beforeExpiry) == nil)
		#expect(answer("192.168.64.30", at: afterExpiry)?.address == "192.168.64.30")
		// Off every subnet of this Mac (another interface in the guest).
		#expect(answer("172.17.0.1", at: beforeExpiry) == nil)
	}

	// Review F8: a copy's config can hold its source's client id until its own report teaches
	// its own; while the source runs and answers that lease's address, the copy's hint must
	// not take it. The copy's own id leads to its own lease.
	@Test("E56: a client-id hint whose address another running VM answers is skipped")
	func aHintSkipsAnAddressAnotherVMAnswers() throws {
		let net = try vmnet()
		let newID = "ff,f1:f5:dd:7f:0:2:0:0:ab:11:aa:bb:cc:dd:ee:ff:0:1"
		let table = clientIDLeases + """
			{
				ip_address=192.168.64.33
				hw_address=\(newID)
				identifier=\(newID)
				lease=0x66aaaaaa
			}
			"""
		let source: Set<String> = ["192.168.64.21"]
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: table, arpText: "",
			hints: SSHDiscovery.Hints(clientID: debianID), interfaces: net, taken: source)
			== nil)
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: table, arpText: "",
			hints: SSHDiscovery.Hints(clientID: newID), interfaces: net, taken: source)?.address
			== "192.168.64.33")
		// The reported address the same: never one another running VM answers.
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: table, arpText: "",
			hints: SSHDiscovery.Hints(reported: "192.168.64.40"), interfaces: net,
			taken: ["192.168.64.40"]) == nil)
	}

	// Review F12: the Mac keeps an ARP entry about 20 minutes. A copy that held its source's
	// address in its last run (both leased under the source's client id) still finds that
	// address under its own MAC after the reboot that gave it a client id and a lease of its
	// own; the source's live lease shows the entry stale.
	@Test("E56: a stale ARP entry under another client's live lease doesn't answer")
	func aStaleARPEntryUnderAnotherLeaseDoesNotAnswer() throws {
		let net = try vmnet()
		let sourceID = "ff,1:2:3"
		let copyID = "ff,4:5:6"
		let table = """
			{
				ip_address=192.168.64.17
				hw_address=\(sourceID)
				identifier=\(sourceID)
				lease=0x66aa0001
			}
			{
				ip_address=192.168.64.21
				hw_address=\(copyID)
				identifier=\(copyID)
				lease=0x66aa0002
			}
			{
				ip_address=192.168.64.30
				hw_address=1,3a:1:2:3:4:5
				identifier=1,3a:1:2:3:4:5
				lease=0x66aa0003
			}
			"""
		let live = Date(timeIntervalSince1970: TimeInterval(0x66aa0000))
		func answer(
			arpAt ip: String, _ hints: SSHDiscovery.Hints, at now: Date = live
		) -> SSHDiscovery.Answer? {
			SSHDiscovery.discover(
				mac: vmMAC, leasesText: table,
				arpText: "? (\(ip)) at 5e:2c:7a:10:44:1 on bridge100 [ethernet]", hints: hints,
				interfaces: net, now: now)
		}
		#expect(answer(arpAt: "192.168.64.17", SSHDiscovery.Hints(clientID: copyID))
			== SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp"))
		// The client id the VM's reports taught holds the address: the entry is its own.
		#expect(answer(arpAt: "192.168.64.17", SSHDiscovery.Hints(clientID: sourceID))
			== SSHDiscovery.Answer(address: "192.168.64.17", source: "arp"))
		// A VM that learned no client id can't tell another's lease from its own; another
		// MAC's lease is another client's all the same.
		#expect(answer(arpAt: "192.168.64.17", SSHDiscovery.Hints())?.address == "192.168.64.17")
		#expect(answer(arpAt: "192.168.64.30", SSHDiscovery.Hints()) == nil)
		// A lease run out holds nothing.
		let runOut = Date(timeIntervalSince1970: TimeInterval(0x66ab0000))
		#expect(answer(arpAt: "192.168.64.17", SSHDiscovery.Hints(clientID: copyID), at: runOut)
			== SSHDiscovery.Answer(address: "192.168.64.17", source: "arp"))
	}

	// C32: bootpd keeps a MAC-keyed lease after the guest's DHCP client moved to a client id
	// (an installer's client, then networkd), so it never goes away; vmnet may since have
	// given its address to another VM. Expired, it answers only while no other client's live
	// lease holds that address — the ARP step's rule.
	@Test("C32: an expired MAC lease on an address another client holds loses to the client id")
	func anExpiredMACLeaseUnderAnotherLiveLeaseLoses() throws {
		let net = try vmnet()
		let ownID = "ff,4:5:6"
		let mac = """
			{
				ip_address=192.168.64.17
				hw_address=1,5e:2c:7a:10:44:1
				identifier=1,5e:2c:7a:10:44:1
				lease=0x66aa0001
			}
			"""
		let own = """
			{
				ip_address=192.168.64.21
				hw_address=\(ownID)
				identifier=\(ownID)
				lease=0x66ab0002
			}
			"""
		let other = """
			{
				ip_address=192.168.64.17
				hw_address=ff,1:2:3
				identifier=ff,1:2:3
				lease=0x66ab0001
			}
			"""
		// The VM's own lease after a long stop: expired, and its address handed to another.
		let ownRunOut = """
			{
				ip_address=192.168.64.21
				hw_address=\(ownID)
				identifier=\(ownID)
				lease=0x66aa5000
			}
			"""
		let otherOnOwn = """
			{
				ip_address=192.168.64.21
				hw_address=ff,7:8:9
				identifier=ff,7:8:9
				lease=0x66ab0005
			}
			"""
		let later = Date(timeIntervalSince1970: TimeInterval(0x66ab0000))
		func answer(
			_ entries: String..., at now: Date = later, taken: Set<String> = []
		) -> SSHDiscovery.Answer? {
			SSHDiscovery.discover(
				mac: vmMAC, leasesText: entries.joined(separator: "\n"), arpText: "",
				hints: SSHDiscovery.Hints(clientID: ownID), interfaces: net, now: now,
				taken: taken)
		}
		let earlier = Date(timeIntervalSince1970: TimeInterval(0x66aa0000))
		#expect(answer(mac, other, own)
			== SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp"))
		// The VM's own client-id lease is newer: its DHCP client moved, live MAC lease or not.
		#expect(answer(mac, own) == SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp"))
		#expect(answer(mac, own, at: earlier)
			== SSHDiscovery.Answer(address: "192.168.64.21", source: "dhcp"))
		// Nor while another client's live lease holds it: never another guest's address.
		#expect(answer(mac, ownRunOut, otherOnOwn)
			== SSHDiscovery.Answer(address: "192.168.64.17", source: "dhcp"))
		#expect(answer(ownRunOut, otherOnOwn) == nil)
		// Unless another running VM answers that address.
		#expect(answer(mac, own, taken: ["192.168.64.21"])
			== SSHDiscovery.Answer(address: "192.168.64.17", source: "dhcp"))
		// Expired, with nothing newer and nobody else on the address: still the guest's last word.
		#expect(answer(mac) == SSHDiscovery.Answer(address: "192.168.64.17", source: "dhcp"))
		// Live and alone, it answers first.
		#expect(answer(mac, at: earlier)
			== SSHDiscovery.Answer(address: "192.168.64.17", source: "dhcp"))
	}

	@Test("E56: the MAC's lease and the ARP table still answer first")
	func macSourcesComeFirst() throws {
		let net = try vmnet()
		let hints = SSHDiscovery.Hints(clientID: debianID, reported: "192.168.64.40")
		#expect(SSHDiscovery.discover(
			mac: "A6:83:E7:12:03:45", leasesText: leases + clientIDLeases, arpText: "",
			hints: hints, interfaces: net)
			== SSHDiscovery.Answer(address: "192.168.64.9", source: "dhcp"))
		let arp = "? (192.168.64.50) at 5e:2c:7a:10:44:1 on bridge100 [ethernet]"
		#expect(SSHDiscovery.discover(
			mac: vmMAC, leasesText: clientIDLeases, arpText: arp, hints: hints,
			interfaces: net)
			== SSHDiscovery.Answer(address: "192.168.64.50", source: "arp"))
	}

	// E56: the vmhost owns a running VM's config and saves every report there; each pass
	// reads what it learned, under the VM's name now.
	@Test("E56: discovery reads the client id and the reported address from the VM's config")
	@MainActor func hintsComeFromTheConfigOnDisk() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "hinted")
			let vm = try VMConfig(name: "hinted", memorySize: 1 << 30, cpuCount: 2)
			var state = SSHConfig()
			state.lastAddress = "192.168.64.17"
			state.dhcpClientID = debianID
			vm.ssh = state
			try vm.saveVMConfig()
			#expect(SSHDiscovery.hints(vm: "hinted", library: machmanVMDir)
				== SSHDiscovery.Hints(clientID: debianID, reported: "192.168.64.17"))
			#expect(SSHDiscovery.hints(vm: "gone", library: machmanVMDir) == SSHDiscovery.Hints())
		}
	}

	// What the guest calls "the Mac", shown in the BSD setup guide before any guest has
	// reported its own default route: the Mac's address on the guest's subnet. C25: it was
	// the ".1 of a /24", wrong for any other vmnet subnet and the router for a bridged guest.
	@Test func hostAddressIsTheMacsAddressOnTheGuestsSubnet() throws {
		func interface(_ address: String, _ mask: String) throws -> SSHDiscovery.IPv4Interface {
			try #require(SSHDiscovery.IPv4Interface(address, mask: mask))
		}
		let vmnet = try interface("192.168.64.1", "255.255.255.0")
		let lan = try interface("192.168.1.20", "255.255.255.0")
		let wide = try interface("10.10.0.1", "255.255.0.0")
		let loopback = try interface("127.0.0.1", "255.0.0.0")
		let all = [loopback, lan, vmnet, wide]
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64.9", interfaces: all)
			== "192.168.64.1")
		#expect(SSHDiscovery.hostAddress(seenFrom: "10.10.3.7", interfaces: all)
			== "10.10.0.1")   // the /24 guess said 10.10.3.1
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.1.50", interfaces: all)
			== "192.168.1.20")   // a bridged guest: the Mac, not the router
		#expect(SSHDiscovery.hostAddress(seenFrom: "172.16.5.5", interfaces: all) == nil)
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64.9", interfaces: []) == nil)
		// The most specific subnet wins.
		let inner = try interface("10.10.3.1", "255.255.255.0")
		#expect(SSHDiscovery.hostAddress(seenFrom: "10.10.3.7", interfaces: [wide, inner])
			== "10.10.3.1")
		#expect(SSHDiscovery.hostAddress(seenFrom: "not-an-address", interfaces: all) == nil)
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64", interfaces: all) == nil)
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64.999", interfaces: all) == nil)
	}

	// The live list reads getifaddrs right: every Mac has loopback.
	@Test func theLiveInterfacesIncludeLoopback() throws {
		let loopback = try #require(SSHDiscovery.IPv4Interface("127.0.0.1", mask: "255.0.0.0"))
		#expect(SSHDiscovery.currentIPv4Interfaces().contains(loopback))
	}

	// C25: one guest whose DHCP hostname isn't UTF-8 (a Latin-1 "café") made the strict
	// read of the whole table fail, so every VM fell back to ARP.
	@Test func aLeaseNameThatIsNotUTF8KeepsTheTableReadable() throws {
		let path = TestEnvironment.scratch + "leases-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: path) }
		let table = Data("{\n\tname=caf".utf8) + Data([0xE9])
			+ Data("\n\tip_address=192.168.64.3\n\thw_address=1,aa:bb:cc:0:0:1\n}\n".utf8)
			+ Data(leases.utf8)
		try table.write(to: URL(fileURLWithPath: path))
		#expect((try? String(contentsOfFile: path, encoding: .utf8)) == nil)   // the old read

		let text = try #require(SSHDiscovery.leases(atPath: path))
		#expect(SSHDiscovery.leaseIP(for: "A6:83:E7:12:03:45", inLeasesText: text)
			== "192.168.64.9")
		#expect(SSHDiscovery.leaseIP(for: "aa:bb:cc:00:00:01", inLeasesText: text)
			== "192.168.64.3")
		#expect(SSHDiscovery.leases(atPath: path + "-missing") == nil)
	}
}
