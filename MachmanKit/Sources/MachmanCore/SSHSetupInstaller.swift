//
//  SSHSetupInstaller.swift
//  MachmanCore
//
//  The SSH setup payload (any guest): one self-contained POSIX script that enables the
//  guest's sshd (per-OS: launchctl on macOS — systemsetup is TCC-gated and fails in fresh
//  VMs —, systemctl/OpenRC/sysrc elsewhere, guided-declarative on NixOS), installs the
//  host's public key for the invoking user, optionally prepares guest→host SSH
//  (--two-way), and reports facts back through the writable SSHReport drop-box. The script
//  itself is parameterless; everything per-VM (marker, host facts) rides the machman.env
//  it sources — see GuestInstaller. The payload is regenerated at every assembly and
//  served READ-ONLY (a writable script would let any guest process swap it before the
//  admin sudo-runs it); only public keys ever cross the share, in either direction. Every
//  artifact the script writes in the guest carries the per-VM marker, so re-runs and
//  --uninstall are exact-match idempotent.
//

import Foundation
import CryptoKit
import SystemConfiguration
import MachmanAPI

enum SSHSetupInstaller: GuestInstallerPayload {
	// One name everywhere: on-disk payload dirs under the VM AND the directories the
	// guest sees inside the share.
	static let directoryName = SSHSetupInfo.directoryName
	static let reportDirectoryName = SSHSetupInfo.reportDirectoryName
	static let scriptName = SSHSetupInfo.scriptName
	// Declared by the script, read back here — one source of truth.
	static var scriptVersion: Int { script.version }

	// The per-VM marker labeling every guest/host-side artifact. Derived from the
	// machine-identity file bytes — stable across renames (the file never moves content),
	// fresh on copies (VMCopier regenerates identity) — never from the VM name.
	static func marker(for config: VMConfig) throws -> String {
		if let existing = existingMarker(for: config) { return existing }
		_ = try config.getVmIdentifier()   // creates + persists the identity file
		guard let minted = existingMarker(for: config) else {
			throw VirtualMachineError.critical(
				"no machine identity to derive \(config.name)'s SSH marker from")
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
	// Returns the public-key line — the only half that ever enters the payload.
	static func ensureKeypair(for config: VMConfig, marker: String) throws -> String {
		let fm = FileManager.default
		let sshDir = config.localURL(file: "ssh")
		try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
		try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
		let keyURL = sshDir.appendingPathComponent("id_ed25519")
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
		let fields = (config.ssh?.guestHostKey ?? "").split(separator: " ")
		guard fields.count >= 2 else {
			try? fm.removeItem(atPath: path)   // nothing reported (yet): no stale pin
			return
		}
		let line = "\(config.effectiveSSHAlias) \(fields[0]) \(fields[1])\n"
		guard (try? line.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
			return
		}
		try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
	}

	// MARK: - Payload

	// Facts about the host and this VM the guest-side half needs (sourced by the script).
	static func environment(for config: VMConfig) throws -> [String: String] {
		let localHost = SCDynamicStoreCopyLocalHostName(nil) as String?
		return [
			"VM_NAME": config.name,
			"MARKER": try marker(for: config),
			"REPORT_DIR_NAME": reportDirectoryName,
			"MOUNT_ROOT": GuestPaths.mounts,
			"HOST_USER": NSUserName(),
			"HOST_NAME": Host.current().localizedName ?? "",
			"HOST_LOCAL": localHost.map { $0 + ".local" } ?? "",
		]
	}

	// Public keys only, in both directions. The host's machine host key is world-readable
	// once Remote Login was ever enabled; absence just skips guest-side pinning (the
	// script tolerates it), so it is served as "make sure this is absent" instead.
	static func extraFiles(for config: VMConfig) throws -> [String: Data?] {
		let publicKey = try ensureKeypair(for: config, marker: try marker(for: config))
		let machineKey = try? String(
			contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8)
		return [
			"host_key.pub": Data((publicKey + "\n").utf8),
			"host_machine_key.pub": machineKey.map { Data($0.utf8) },
		]
	}

	// The guest-writable drop-box: a sibling of the payload dir, so the script addresses
	// it payload-relatively and it rides the same share (or the same sshfs mount).
	static func reportDirectoryURL(for config: VMConfig) -> URL {
		GuestInstallerWriter.payloadDirectory(named: reportDirectoryName, for: config)
	}

	static func reportFilePath(for config: VMConfig) -> String {
		reportDirectoryURL(for: config)
			.appendingPathComponent(SSHSetupInfo.reportName).path
	}

	// Writes <vmdir>/share/SSHSetup/ (script 0755 + machman.env + public keys) and the
	// empty writable <vmdir>/share/SSHReport/; returns both. Regenerated at every assembly.
	@discardableResult
	static func writePayload(for config: VMConfig) throws -> (payload: URL, report: URL) {
		let marker = try marker(for: config)
		// Cache the marker for reset-time cleanup (creates the ssh state on first use).
		if config.ssh?.marker != marker {
			var state = config.ssh ?? SSHConfig()
			state.marker = marker
			config.ssh = state
			try config.saveVMConfig()
		}
		let report = reportDirectoryURL(for: config)
		try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
		GuestInstallerWriter.removeLegacyPayload(named: reportDirectoryName, for: config)
		let payload = try GuestInstallerWriter.write(Self.self, for: config)
		// The alias (and so the pin's key) can have changed while the VM was stopped.
		writeKnownHosts(for: config)
		return (payload, report)
	}

	// Drop both share dirs from disk: the device was removed, or vm.ssh.reset wiped
	// everything. Keys and config.ssh are the caller's business.
	static func removePayload(for config: VMConfig) {
		let fm = FileManager.default
		for name in [directoryName, reportDirectoryName] {
			try? fm.removeItem(at: GuestInstallerWriter.payloadDirectory(
				named: name, for: config))
			GuestInstallerWriter.removeLegacyPayload(named: name, for: config)
		}
	}

	// MARK: - The script

	// The whole installer — GuestScripts/ssh-setup.sh, embedded at build time. Idempotent:
	// key installs dedupe, the guest-side config block is replaced wholesale between marker
	// lines, and --uninstall removes exactly what carries the marker. sshd is never
	// disabled by --uninstall.
	static var script: EmbeddedScript {
		EmbeddedScript(bytes: PackageResources.ssh_setup_sh)
	}

	// The shared sh helpers (output vocabulary, terminal detection, prompts, the run
	// wrapper) the script sources beside itself.
	static var sharedLibrary: EmbeddedScript? {
		EmbeddedScript(bytes: PackageResources.machman_lib_sh)
	}
}
