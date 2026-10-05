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

	// The address the guest reaches this Mac at. vmnet's bootpd hands out <net>.x and
	// answers on <net>.1 — the same value the guest's own default route reports, derived
	// here so the UI can show it before any guest has reported anything.
	static func hostAddress(seenFrom guestAddress: String) -> String? {
		let parts = guestAddress.split(separator: ".")
		guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
		return parts.dropLast().joined(separator: ".") + ".1"
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
