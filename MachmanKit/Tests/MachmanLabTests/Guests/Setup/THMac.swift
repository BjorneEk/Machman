//
//  THMac.swift
//  MachmanLabTests
//
//  "The Mac" for a Guest Setup guest: r3-td's lab sshd with its home = the agent scope's fake
//  home (where the product writes its reverse approvals, so an approved guest key lets the
//  guest in), bound on the VZ NAT bridge for VZ guests or on 127.0.0.1 for QEMU guests (their
//  lab gateway 10.0.2.100 forwards port 22 to it). The payload pins its host key
//  (MACHMAN_LAB_SSHD_HOSTKEY), so a guest that reached any other sshd fails host-key
//  verification and never authenticates.
//
//  A VZ guest's "Mac" is its default gateway's port 22 — this Mac's real Remote Login. Before
//  any install run THNet loads an nft ruleset in the guest that sends <gateway>:22 to the lab
//  sshd and refuses every other connection out of the guest (DHCP and loopback excepted), and
//  persists it for every later boot.
//

import Foundation
import MachmanAPI

final class THMac: @unchecked Sendable {
	let sshd: LabSSHD
	private let lock = NSLock()
	private var added: [String] = []

	private init(sshd: LabSSHD) {
		self.sshd = sshd
	}

	/// The lab sshd for `scope`: on the VZ bridge (once a NAT VM made it) or on loopback.
	/// nil when the doctor says a bridge listener would make the firewall prompt.
	static func start(bind: LabSSHD.Bind, scope: LabScope) async throws -> THMac? {
		if bind == .vmnet {
			let doctor = await LabSSHD.doctor()
			guard doctor.bridgeOK else {
				LabScripts.log("th: no lab sshd on the bridge (doctor):\n\(doctor.output)")
				return nil
			}
		}
		// One lab sshd per run: a scope that failed half-way may have left its own.
		_ = try? await LabScripts.run(LabScripts.sshd, ["stop", Lab.runDir], timeout: 60)
		let sshd = try await LabSSHD.start(bind: bind, home: scope.homeDir)
		return THMac(sshd: sshd)
	}

	var port: Int { sshd.port }
	var logPath: String { sshd.root + "/sshd/sshd.log" }
	private var authorizedKeysPath: String { sshd.root + "/sshd/authorized_keys" }

	/// The known_hosts line a guest pins for `name` (TOFU answered in advance).
	func hostKeyLine(for name: String) throws -> String { try sshd.knownHostsLine(for: name) }

	/// Lets `publicKey` in as the Mac user until deauthorize (the bootstrap's temporary keys).
	func authorize(_ publicKey: String) async throws {
		let line = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
		try await sshd.authorize(publicKey: line)
		lock.withLock { added.append(line) }
	}

	/// Drops every key authorize added (the product's own grants live in the scope's home).
	func deauthorize() {
		let gone = lock.withLock { () -> Set<String> in
			defer { added = [] }
			return Set(added)
		}
		guard !gone.isEmpty,
			let text = try? String(contentsOfFile: authorizedKeysPath, encoding: .utf8)
		else { return }
		let kept = text.split(separator: "\n").map(String.init).filter {
			!gone.contains($0.trimmingCharacters(in: .whitespaces))
		}
		try? (kept.map { $0 + "\n" }.joined()).write(
			toFile: authorizedKeysPath, atomically: true, encoding: .utf8)
	}

	/// sshd's log lines that contain `text`.
	func log(containing text: String) -> [String] {
		// Lossy: a client's garbage (a port probe) must not hide the rest of the log.
		let data = FileManager.default.contents(atPath: logPath) ?? Data()
		let log = String(decoding: data, as: UTF8.self)
		// sshd ends its lines with CRLF: one Character to Swift, so split on any newline.
		return log.split(whereSeparator: \.isNewline).map(String.init)
			.filter { text.isEmpty || $0.contains(text) }
	}

	/// Accepted logins so far (sshd: "Accepted publickey for <user> from <address> …").
	var acceptedLogins: [String] { log(containing: "Accepted publickey for") }

	/// Whether more than `count` logins are logged within 10 s (a session's lines reach the
	/// log through the listener, a moment after the client returns).
	func waitForLogins(moreThan count: Int) async -> Bool {
		let deadline = ContinuousClock.now + .seconds(10)
		while acceptedLogins.count <= count {
			if ContinuousClock.now >= deadline { return false }
			try? await Task.sleep(for: .milliseconds(250))
		}
		return true
	}

	func stop() async {
		deauthorize()
		await sshd.stop()
		// Its log goes with the run's transcripts (the report keeps them).
		let copy = Lab.transcriptsDir + "/th-sshd-\(THCounter.next()).log"
		try? FileManager.default.createDirectory(
			atPath: Lab.transcriptsDir, withIntermediateDirectories: true)
		try? FileManager.default.copyItem(atPath: logPath, toPath: copy)
	}
}

/// The guest-side network rules of a VZ guest (see THMac).
enum THNet {
	/// The ruleset for a guest whose gateway is `gateway`: its port 22 goes to the lab sshd on
	/// `gateway:port` (1 = refused, when no lab sshd runs); nothing else leaves but DHCP.
	static func ruleset(gateway: String, port: Int) -> [String] {
		[
			"#!/usr/sbin/nft -f",
			"# r3-th: the lab's Mac is the lab sshd; nothing else leaves this guest.",
			"flush ruleset",
			"table ip th_lab_nat {",
			"  chain out {",
			"    type nat hook output priority -100; policy accept;",
			"    ip daddr \(gateway) tcp dport 22 dnat to \(gateway):\(port)",
			"  }",
			"}",
			"table inet th_lab {",
			"  chain out {",
			"    type filter hook output priority 0; policy accept;",
			"    oif \"lo\" accept",
			"    udp dport 67 accept",
			"    ip daddr \(gateway) tcp dport \(port) accept",
			"    meta l4proto tcp reject with tcp reset",
			"    reject",
			"  }",
			"}",
		]
	}

	/// The file the guest's init loads the ruleset from at boot.
	static func rulesFile(_ kind: THGuestKind) -> String {
		kind == .alpine ? "/etc/nftables.nft" : "/etc/nftables.conf"
	}

	/// Shell lines (root, one per console command) that write, load and persist the rules.
	static func install(_ kind: THGuestKind, gateway: String, port: Int) -> [String] {
		let file = rulesFile(kind)
		let lines = ruleset(gateway: gateway, port: port).map(ShellQuote.single)
			.joined(separator: " ")
		var commands = [
			"printf '%s\\n' \(lines) > \(file)",
			"nft -f \(file)",
		]
		switch kind {
		case .alpine:
			commands.append("rc-update add nftables boot >/dev/null 2>&1; true")
		case .debianSysv:
			// ifupdown runs this before an interface comes up, at every boot.
			commands.append(
				"mkdir -p /etc/network/if-pre-up.d && printf '%s\\n' '#!/bin/sh' "
					+ ShellQuote.single(
						"nft list table inet th_lab >/dev/null 2>&1 || nft -f \(file)")
					+ " > /etc/network/if-pre-up.d/th-lab && chmod 755"
					+ " /etc/network/if-pre-up.d/th-lab")
		default:
			commands.append("systemctl enable nftables.service >/dev/null 2>&1")
		}
		return commands
	}

	/// A root command that succeeds only while the rules are loaded.
	static let loadedCheck = "nft list table inet th_lab >/dev/null && "
		+ "nft list table ip th_lab_nat >/dev/null"
}
