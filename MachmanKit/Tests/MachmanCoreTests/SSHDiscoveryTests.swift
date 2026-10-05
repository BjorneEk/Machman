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

	// vmnet answers on <net>.1 — what the guest calls "the Mac", shown in the BSD setup
	// guide before any guest has reported its own default route.
	@Test func hostAddressIsTheGuestSubnetsGateway() {
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64.9") == "192.168.64.1")
		#expect(SSHDiscovery.hostAddress(seenFrom: "10.0.3.55") == "10.0.3.1")
		#expect(SSHDiscovery.hostAddress(seenFrom: "not-an-address") == nil)
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64") == nil)
		#expect(SSHDiscovery.hostAddress(seenFrom: "192.168.64.999") == nil)
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
