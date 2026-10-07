//
//  SSHDiscovery.swift
//  MachmanCore
//
//  Guest address discovery for SSH (daemon-side; host-global inputs): the vmnet DHCP
//  lease table (/var/db/dhcpd_leases, bootpd's format) keyed by the VM's in-use MAC, the
//  ARP table as fallback, then what the guest's reports taught the VM's config (the DHCP
//  client id its lease is kept under, the address it reported), and a TCP:22 liveness probe
//  so an address is only surfaced once sshd actually answers. Pure string parsers +
//  injectable inputs — tests never read /var/db or run arp. One normalization rule makes
//  matching work at all: bootpd (and arp) strip leading zeros per MAC octet, VZMACAddress
//  strings don't.
//

import Foundation
import MachmanAPI
import Network
import os

enum SSHDiscovery {
	struct Answer: Equatable, Sendable {
		var address: String
		var source: String   // "dhcp" | "arp" | "report" — SSHInfo.addressSource vocabulary
		// What the guest's reports taught that this answer rests on (a client id's lease or a
		// reported address); nil for the MAC's lease and ARP. A later report that teaches
		// something else can move it (review F5).
		var hints: Hints?

		init(address: String, source: String, hints: Hints? = nil) {
			self.address = address
			self.source = source
			self.hints = hints
		}
	}

	// What the VM's config owner learned from the guest's reports (E56): the DHCP client id
	// bootpd keeps the guest's lease under, and the address the guest last reported.
	struct Hints: Equatable, Sendable {
		var clientID: String?
		var reported: String?

		init(clientID: String? = nil, reported: String? = nil) {
			self.clientID = clientID
			self.reported = reported
		}
	}

	// "0a:0B:0c:01:02:03" and "a:b:c:1:2:3" become the same key.
	static func normalizedMAC(_ mac: String) -> String {
		mac.lowercased().split(separator: ":").map { octet in
			let stripped = octet.drop { $0 == "0" }
			return stripped.isEmpty ? "0" : String(stripped)
		}.joined(separator: ":")
	}

	// MARK: - dhcpd_leases

	// One entry of bootpd's table. hw_address and identifier carry a "type," prefix: 1 is an
	// Ethernet MAC. A client that sends a DHCP client identifier is kept under it — type ff,
	// RFC 4361's IAID and DUID, what systemd-networkd and dhcpcd send by default — so its
	// entry names no MAC at all (E56).
	struct Lease: Equatable, Sendable {
		var ip: String
		var hardware: String     // hw_address's value, normalized
		var identifier: String   // "type,value", normalized; hw_address when there is none
		var expiry: UInt64       // lease=, seconds since 1970 (hex)

		var isHardware: Bool { identifier.hasPrefix("1,") || !identifier.contains(",") }
	}

	// Entries are brace-delimited key=value blocks, in file order.
	static func leases(inText text: String) -> [Lease] {
		var found: [Lease] = []
		var current: [String: String] = [:]
		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line == "{" {
				current = [:]
			} else if line == "}" {
				if let hw = current["hw_address"], let ip = current["ip_address"] {
					let value = hw.split(separator: ",").last.map(String.init) ?? hw
					found.append(Lease(
						ip: ip, hardware: normalizedMAC(value),
						identifier: normalizedClientID(current["identifier"] ?? hw),
						expiry: current["lease"].flatMap {
							UInt64($0.dropFirst($0.hasPrefix("0x") ? 2 : 0), radix: 16)
						} ?? 0))
				}
				current = [:]
			} else if let eq = line.firstIndex(of: "=") {
				current[String(line[..<eq])] = String(line[line.index(after: eq)...])
			}
		}
		return found
	}

	// "FF,F1:F5:DD:7F:00:02" and "ff,f1:f5:dd:7f:0:2" become the same key.
	static func normalizedClientID(_ id: String) -> String {
		guard let comma = id.firstIndex(of: ",") else { return normalizedMAC(id) }
		let value = String(id[id.index(after: comma)...])
		return id[..<comma].lowercased() + "," + normalizedMAC(value)
	}

	// The same client can appear in several entries (renewals): the latest lease wins, and
	// of two equal ones the later in the file.
	private static func newest(_ leases: [Lease], where matches: (Lease) -> Bool) -> Lease? {
		leases.reduce(nil) { best, lease in
			guard matches(lease) else { return best }
			guard let best else { return lease }
			return lease.expiry >= best.expiry ? lease : best
		}
	}

	static func leaseIP(for mac: String, inLeasesText text: String) -> String? {
		leaseIP(for: mac, in: leases(inText: text))
	}

	static func leaseIP(for mac: String, in leases: [Lease]) -> String? {
		let wanted = normalizedMAC(mac)
		return newest(leases) { $0.hardware == wanted }?.ip
	}

	// The address of the lease kept under a client id the guest was seen with (E56).
	static func leaseIP(forClientID id: String, in leases: [Lease]) -> String? {
		let wanted = normalizedClientID(id)
		return newest(leases) { $0.identifier == wanted }?.ip
	}

	// The client id of the lease that holds `ip`, when that lease is kept under one rather
	// than a MAC — what a guest's reported address teaches the VM (E56).
	static func clientID(holding ip: String, inLeasesText text: String) -> String? {
		guard let lease = newest(leases(inText: text), where: { $0.ip == ip }),
			!lease.isHardware else { return nil }
		return lease.identifier
	}

	// MARK: - ARP table

	// `arp -an` lines: "? (192.168.64.5) at a6:83:e7:12:3:45 on bridge100 …";
	// "(incomplete)" entries carry no MAC.
	static func arpIP(for mac: String, inARPOutput text: String) -> String? {
		let wanted = normalizedMAC(mac)
		for line in text.components(separatedBy: .newlines) {
			guard let open = line.firstIndex(of: "("),
				let close = line.firstIndex(of: ")"), open < close,
				let atRange = line.range(of: " at ") else { continue }
			let entryMAC = line[atRange.upperBound...].split(separator: " ").first
				.map(String.init) ?? ""
			guard entryMAC.contains(":") else { continue }   // "(incomplete)"
			if normalizedMAC(entryMAC) == wanted {
				return String(line[line.index(after: open)..<close])
			}
		}
		return nil
	}

	// MARK: - This Mac, seen from the guest

	// One IPv4 interface of this Mac: its address and netmask, host byte order.
	struct IPv4Interface: Equatable, Sendable {
		var address: UInt32
		var mask: UInt32

		init(address: UInt32, mask: UInt32) {
			self.address = address
			self.mask = mask
		}

		init?(_ address: String, mask: String) {
			guard let address = SSHDiscovery.ipv4(address), let mask = SSHDiscovery.ipv4(mask)
			else { return nil }
			self.init(address: address, mask: mask)
		}
	}

	// The address the guest reaches this Mac at, shown before any guest has reported its own
	// route: the Mac's address on the interface whose subnet holds the guest — vmnet's bridge
	// for a NAT guest, whatever subnet and mask vmnet was given, and the Mac's LAN address for
	// a bridged one. The most specific subnet wins; none holding the guest gives nil, never a
	// guess. (The ".1 of a /24" this replaced was wrong for any other vmnet subnet, and named
	// the router for a bridged guest.) vmnet's own config is readable by root only.
	static func hostAddress(
		seenFrom guestAddress: String, interfaces: [IPv4Interface] = currentIPv4Interfaces()
	) -> String? {
		guard let guest = ipv4(guestAddress) else { return nil }
		return interfaces
			.filter { $0.mask != 0 && $0.address != guest
				&& $0.address & $0.mask == guest & $0.mask }
			.max { $0.mask.nonzeroBitCount < $1.mask.nonzeroBitCount }
			.map { dotted($0.address) }
	}

	// The Mac's IPv4 interfaces that are up, from getifaddrs.
	static func currentIPv4Interfaces() -> [IPv4Interface] {
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return [] }
		defer { freeifaddrs(head) }
		var result: [IPv4Interface] = []
		for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let item = entry.pointee
			guard item.ifa_flags & UInt32(IFF_UP) != 0, let address = item.ifa_addr,
				address.pointee.sa_family == sa_family_t(AF_INET), let mask = item.ifa_netmask
			else { continue }
			result.append(IPv4Interface(address: ipv4(of: address), mask: ipv4(of: mask)))
		}
		return result
	}

	// A netmask's sockaddr can be cut short (its sa_len); the bytes it leaves out are zero.
	private static func ipv4(of socketAddress: UnsafeMutablePointer<sockaddr>) -> UInt32 {
		var storage = sockaddr_in()
		let length = min(Int(socketAddress.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
		withUnsafeMutableBytes(of: &storage) {
			$0.copyMemory(from: UnsafeRawBufferPointer(start: socketAddress, count: length))
		}
		return UInt32(bigEndian: storage.sin_addr.s_addr)
	}

	static func ipv4(_ text: String) -> UInt32? {
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4 else { return nil }
		var value: UInt32 = 0
		for part in parts {
			guard let octet = UInt8(part) else { return nil }
			value = value << 8 | UInt32(octet)
		}
		return value
	}

	static func dotted(_ address: UInt32) -> String {
		[24, 16, 8, 0].map { String(address >> $0 & 0xFF) }.joined(separator: ".")
	}

	// MARK: - Liveness

	// Under a test suite (the lab) no connect leaves for a guest unless the run opted into the
	// local network: a TCP connect to the VM network can raise macOS's Local Network prompt.
	// Loopback stays allowed. nil (every process outside test mode) allows everything.
	static func probeAllowed(host: String, lab: LabEnvironment? = .current) -> Bool {
		guard let lab, !lab.allowsLocalNetwork else { return true }
		return ["127.0.0.1", "::1", "localhost"].contains(host)
	}

	private static let refusedProbeLogged = OSAllocatedUnfairLock(initialState: false)

	static func probeTCP(
		host: String, port: UInt16 = 22, timeout: TimeInterval = 1.0
	) async -> Bool {
		guard probeAllowed(host: host) else {
			if refusedProbeLogged.withLock({ logged in defer { logged = true }; return !logged }) {
				MachmanLogger.log(.log, "test mode: no TCP probes to guests "
					+ "(MACHMAN_LAB_LOCAL_NETWORK is not 1); \(host):\(port) reads as closed")
			}
			return false
		}
		final class Once: @unchecked Sendable {
			private let lock = NSLock()
			private var done = false
			func claim() -> Bool {
				lock.lock()
				defer { lock.unlock() }
				if done { return false }
				done = true
				return true
			}
		}
		guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
		return await withCheckedContinuation { cont in
			let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
			let once = Once()
			let finish: @Sendable (Bool) -> Void = { ok in
				guard once.claim() else { return }
				conn.cancel()
				cont.resume(returning: ok)
			}
			conn.stateUpdateHandler = { state in
				switch state {
				case .ready: finish(true)
				case .failed, .cancelled: finish(false)
				default: break
				}
			}
			conn.start(queue: .global())
			DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
				finish(false)
			}
		}
	}

	// MARK: - Probes

	// Whom a pass looks for: the VM's in-use MAC, and its config by the VM's current name —
	// what the guest's reports taught it (E56).
	struct Lookup: Equatable, Sendable {
		var mac: String
		var vm: String
		var library: String
		// What the other running VMs answer now: a hint never takes one of those (review F8).
		var taken: Set<String> = []
	}

	// Where discovery looks: the live tables, the VM's config and a connect to port 22, or a
	// test's stand-ins.
	struct Probes: Sendable {
		var address: @Sendable (_ lookup: Lookup) async -> Answer?
		var sshd: @Sendable (_ address: String) async -> Bool

		static let live = Probes(
			// Detached: the live loaders read /var/db and the config and run arp — off the
			// main actor.
			address: { lookup in await Task.detached { discoverLive(lookup) }.value },
			sshd: { await probeTCP(host: $0, timeout: 1.5) })
	}

	// MARK: - Orchestration

	// The MAC's lease first (authoritative while fresh), ARP as fallback (needs recent guest
	// traffic). A guest whose DHCP client sends a client id has no lease under its MAC
	// (E56): next the lease kept under the client id the VM's config learned, then the
	// address the guest reported — taken only on a subnet this Mac is on, and never while
	// another client holds a live lease on it (a static address, or one whose id was not
	// learned yet). Neither hint takes an address another running VM answers (`taken`): a
	// copy's config can hold its source's client id until its own report teaches its own
	// (review F8), and the source's answer wins. Deliberately NO liveness gate: the address
	// is a fact of the running VM whether or not anything listens on it yet (a guest without
	// sshd still has an IP worth showing) — ssh reachability is the connection's own
	// business. The cost is that a stale lease can win briefly after renumbering; a reboot or
	// the refresh button re-resolves.
	static func discover(
		mac: String, leasesText: String?, arpText: String?, hints: Hints = Hints(),
		interfaces: @autoclosure () -> [IPv4Interface] = currentIPv4Interfaces(),
		now: Date = Date(), taken: Set<String> = []
	) -> Answer? {
		let table = leasesText.map(leases(inText:)) ?? []
		if let ip = leaseIP(for: mac, in: table) {
			return Answer(address: ip, source: "dhcp")
		}
		if let arpText, let ip = arpIP(for: mac, inARPOutput: arpText) {
			return Answer(address: ip, source: "arp")
		}
		if let id = hints.clientID, let ip = leaseIP(forClientID: id, in: table),
			!taken.contains(ip) {
			return Answer(address: ip, source: "dhcp", hints: hints)
		}
		if let reported = hints.reported, !taken.contains(reported),
			hostAddress(seenFrom: reported, interfaces: interfaces()) != nil {
			// A lease of this VM's would have answered above: a live one on the address is
			// a client nothing ties to this VM.
			let seconds = UInt64(max(0, now.timeIntervalSince1970))
			if !table.contains(where: { $0.ip == reported && $0.expiry > seconds }) {
				return Answer(address: reported, source: "report", hints: hints)
			}
		}
		return nil
	}

	// The live variant — reads /var/db/dhcpd_leases and the VM's config, and runs arp. Call
	// off the main actor (Process + file reads block their thread).
	static func discoverLive(_ lookup: Lookup) -> Answer? {
		discover(
			mac: lookup.mac, leasesText: leases(atPath: leasesPath), arpText: currentARPOutput(),
			hints: hints(vm: lookup.vm, library: lookup.library), taken: lookup.taken)
	}

	// What the guest's reports taught the VM, read decode-only from its config: while the VM
	// runs its vmhost owns the config and saves every report there (E56).
	static func hints(vm name: String, library: String) -> Hints {
		let ssh = BootGuard.peekConfig(name: name, library: library)?.ssh
		return Hints(clientID: ssh?.dhcpClientID, reported: ssh?.lastAddress)
	}

	static let leasesPath = "/var/db/dhcpd_leases"

	// Decoded lossily: name= is the hostname a guest chose, and one that isn't UTF-8 made a
	// strict decode fail for the WHOLE table — every VM fell back to ARP (C25).
	static func leases(atPath path: String) -> String? {
		FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
	}

	static func currentARPOutput() -> String? {
		let arp = Process()
		arp.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
		arp.arguments = ["-an"]
		let pipe = Pipe()
		arp.standardOutput = pipe
		arp.standardError = FileHandle.nullDevice
		do {
			try arp.run()
		} catch {
			return nil
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		arp.waitUntilExit()
		return String(decoding: data, as: UTF8.self)
	}
}
