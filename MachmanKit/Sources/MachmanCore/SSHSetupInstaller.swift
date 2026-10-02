//
//  SSHSetupInstaller.swift
//  MachmanCore
//
//  The per-VM SSH identity machinery: the marker labeling every guest/host-side
//  artifact, the host→guest keypair, and the pinned guest host key the session tabs
//  verify against. The SSH *payload* this file used to generate was folded into
//  GuestSetupInstaller (1.0.7); the identities outlive any one payload, so they stay
//  here under the name the rest of the code already knows.
//

import Foundation
import CryptoKit
import MachmanAPI

enum SSHSetupInstaller {
	// The per-VM marker labeling every guest/host-side artifact. Derived from the
	// machine-identity file bytes — stable across renames (the file never moves content),
	// fresh on copies (VMCopier regenerates identity) — never from the VM name.
	static func marker(for config: VMConfig) throws -> String {
		if let existing = existingMarker(for: config) { return existing }
		_ = try config.getVmIdentifier()   // creates + persists the identity file
		guard let minted = existingMarker(for: config) else {
			throw VirtualMachineError.critical(
				"\(config.name) has no machine identity to derive its SSH marker from")
		}
		return minted
	}

	// Read-only lookup for the daemon (which must never write a hosted VM's dir): nil
	// until an identity file exists — and one always does once a payload was written.
	static func existingMarker(for config: VMConfig) -> String? {
		let fm = FileManager.default
		var data = fm.contents(atPath: config.vmIdentifierPath())
		if data?.isEmpty != false {
			data = fm.contents(atPath: config.macMachineIdPath())
		}
		guard let bytes = data, !bytes.isEmpty else { return nil }
		let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
			.joined().prefix(12)
		return "machman-\(hex)"
	}

	// The per-VM host→guest keypair, minted lazily (0600, in the 0700 <vmdir>/ssh dir).
	// Returns the public-key line — the only half that ever enters a payload.
	static func ensureKeypair(for config: VMConfig, marker: String) throws -> String {
		let fm = FileManager.default
		let sshDir = config.localURL(file: "ssh")
		try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
		try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
		let keyURL = sshDir.appendingPathComponent("id_ed25519")
		let pubPath = keyURL.path + ".pub"
		// A copied VM directory carries the source VM's keypair; the comment's leading
		// marker word exposes that. Each VM identity keys itself — re-mint on drift
		// (and when the public half is missing, since only that half enters payloads).
		if fm.fileExists(atPath: keyURL.path) {
			let comment = (try? String(contentsOfFile: pubPath, encoding: .utf8))
				.flatMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) }
			if comment != marker {
				try? fm.removeItem(at: keyURL)
				try? fm.removeItem(atPath: pubPath)
				MachmanLogger.log(.log,
					"\(config.name): re-minting the SSH key a VM copy brought along")
			}
		}
		if !fm.fileExists(atPath: keyURL.path) {
			let keygen = Process()
			keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
			keygen.arguments = [
				"-q", "-t", "ed25519", "-N", "", "-C", "\(marker) \(config.name)",
				"-f", keyURL.path,
			]
			try keygen.run()
			keygen.waitUntilExit()
			guard keygen.terminationStatus == 0 else {
				throw VirtualMachineError.critical(
					"ssh-keygen failed (\(keygen.terminationStatus)) for \(config.name)")
			}
		}
		try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
		return try String(contentsOfFile: keyURL.path + ".pub", encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Pinned guest identity

	static func knownHostsPath(for config: VMConfig) -> String {
		config.configFilePath(file: "ssh/known_hosts")
	}

	// The guest's own host key, pinned under the VM's alias rather than its address —
	// the HostKeyAlias trick the managed ~/.ssh file already uses, so the pin survives
	// the NAT lease moving. In-app session tabs point ssh at this file, which is how they
	// verify the guest without ever writing the user's ~/.ssh/known_hosts.
	static func writeKnownHosts(for config: VMConfig) {
		let path = knownHostsPath(for: config)
		let fm = FileManager.default
		guard fm.fileExists(atPath: config.configFilePath(file: "ssh")) else { return }
		let key = config.ssh?.guestHostKey ?? ""
		let fields = key.split(separator: " ")
		guard GuestValueRule.isPublicKeyLine(key) else {
			try? fm.removeItem(atPath: path)   // nothing reported (yet): no stale pin
			return
		}
		let line = "\(config.effectiveSSHAlias) \(fields[0]) \(fields[1])\n"
		guard (try? line.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
			return
		}
		try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
	}
}
