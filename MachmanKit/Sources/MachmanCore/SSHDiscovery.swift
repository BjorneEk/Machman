//
//  SSHDiscovery.swift
//  MachmanCore
//
//  Guest address discovery for SSH (daemon-side; host-global inputs): the vmnet DHCP
//  lease table (/var/db/dhcpd_leases, bootpd's format) keyed by the VM's in-use MAC, the
//  ARP table as fallback, and a TCP:22 liveness probe so an address is only surfaced once
//  sshd actually answers. Pure string parsers + injectable inputs — tests never read
//  /var/db or run arp. One normalization rule makes matching work at all: bootpd (and
//  arp) strip leading zeros per MAC octet, VZMACAddress strings don't.
//

import Foundation
import Network

enum SSHDiscovery {
	struct Answer: Equatable, Sendable {
		var address: String
		var source: String   // "dhcp" | "arp" — SSHInfo.addressSource vocabulary
	}

	// "0a:0B:0c:01:02:03" and "a:b:c:1:2:3" become the same key.
	static func normalizedMAC(_ mac: String) -> String {
		mac.lowercased().split(separator: ":").map { octet in
			let stripped = octet.drop { $0 == "0" }
			return stripped.isEmpty ? "0" : String(stripped)
		}.joined(separator: ":")
	}

	// MARK: - dhcpd_leases

	// Entries are brace-delimited key=value blocks; the same MAC can appear in several
	// (renewals) — the highest lease timestamp wins. hw_address carries a "type," prefix.
	static func leaseIP(for mac: String, inLeasesText text: String) -> String? {
		let wanted = normalizedMAC(mac)
		var bestIP: String?
		var bestLease: UInt64 = 0
		var current: [String: String] = [:]
		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line == "{" {
				current = [:]
			} else if line == "}" {
				if let hw = current["hw_address"], let ip = current["ip_address"] {
					let macPart = hw.split(separator: ",").last.map(String.init) ?? hw
					if normalizedMAC(macPart) == wanted {
						let lease = current["lease"].flatMap {
							UInt64($0.dropFirst($0.hasPrefix("0x") ? 2 : 0), radix: 16)
						} ?? 0
						if bestIP == nil || lease >= bestLease {
							bestIP = ip
							bestLease = lease
						}
					}
				}
				current = [:]
			} else if let eq = line.firstIndex(of: "=") {
				current[String(line[..<eq])] = String(line[line.index(after: eq)...])
			}
		}
		return bestIP
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

	static func probeTCP(
		host: String, port: UInt16 = 22, timeout: TimeInterval = 1.0
	) async -> Bool {
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

	// MARK: - Orchestration

	// Leases first (authoritative while fresh), ARP as fallback (needs recent guest
	// traffic). Deliberately NO liveness gate: the address is a fact of the running VM
	// whether or not anything listens on it yet (a guest without sshd still has an IP
	// worth showing) — ssh reachability is the connection's own business. The cost is
	// that a stale lease can win briefly after renumbering; a reboot or the refresh
	// button re-resolves.
	static func discover(mac: String, leasesText: String?, arpText: String?) -> Answer? {
		if let leasesText, let ip = leaseIP(for: mac, inLeasesText: leasesText) {
			return Answer(address: ip, source: "dhcp")
		}
		if let arpText, let ip = arpIP(for: mac, inARPOutput: arpText) {
			return Answer(address: ip, source: "arp")
		}
		return nil
	}

	// The live variant — reads /var/db/dhcpd_leases and runs arp. Call off the main
	// actor (Process + file reads block their thread).
	static func discoverLive(mac: String) -> Answer? {
		discover(mac: mac, leasesText: leases(atPath: leasesPath), arpText: currentARPOutput())
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
