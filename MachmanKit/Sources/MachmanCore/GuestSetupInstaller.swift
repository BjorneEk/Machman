//
//  GuestSetupInstaller.swift
//  MachmanCore
//
//  The unified installer payload (1.0.7, any guest): ONE assembled POSIX script that sets
//  up everything configurable from inside a guest — console logins, kernel console
//  output, SSH, guest→host SSH, sshfs, and boot automounts — plus the writable GuestReport
//  drop-box the guest reports back through. Supersedes the console-login and SSH-setup
//  payloads; the SSH key/marker machinery stays in SSHSetupInstaller (it outlives any one
//  payload). The script is parameterless: everything per-VM rides machman.env and the
//  mounts.list beside it. Served READ-ONLY (a writable script would let any guest process
//  swap it before the admin sudo-runs it); only public keys ever cross the share.
//

import Foundation
import SystemConfiguration
import MachmanAPI

enum GuestSetupInstaller: GuestInstallerPayload {
	// One name everywhere: on-disk payload dirs under the VM AND the directories the
	// guest sees inside the share.
	static let directoryName = GuestSetupInstallerInfo.directoryName
	static let reportDirectoryName = GuestSetupInstallerInfo.reportDirectoryName
	static let scriptName = GuestSetupInstallerInfo.scriptName
	// Declared by the script's 00-prelude module, read back here — one source of truth.
	static var scriptVersion: Int { script.version }

	// The whole installer, assembled from GuestScripts/setup/ in module order.
	static var script: EmbeddedScript { GuestSetupScript.assembled }

	// Facts about the host and this VM the guest-side half needs (sourced by the script).
	// COPY_OF only in a copy's payloads, until a report says it renewed its identity.
	static func environment(for config: VMConfig) throws -> [String: String] {
		let localHost = SCDynamicStoreCopyLocalHostName(nil) as String?
		let bootMode: String = {
			switch config.boot {
			case .macOS: return "macos"
			case .linuxKernel: return "kernel"
			default: return "efi"
			}
		}()
		var copy: [String: String] = [:]
		if let source = config.setup?.copyOf {
			copy["COPY_OF"] = source
		}
		return copy.merging([
			"VM_NAME": config.name,
			"MARKER": try SSHSetupInstaller.marker(for: config),
			"REPORT_DIR_NAME": reportDirectoryName,
			"MOUNT_ROOT": GuestPaths.mounts,
			// Where the guest mounts the share: macOS automounts it under My Shared Files.
			"SHARE_ROOT": bootMode == "macos" ? GuestPaths.macOSAutomount : GuestPaths.share,
			"SHARE_TAG": GuestPaths.shareTag,
			"SHARE_HOST_PATH": stableSharePath(for: config)
				?? GuestInstallerWriter.payloadRoot(for: config).path,
			"BOOT_MODE": bootMode,
			"CONSOLE_COUNT": String(config.consolePorts.filter(\.enabled).count),
			"UART_COUNT": String(config.uartPorts.filter(\.enabled).count),
			"HOST_USER": NSUserName(),
			// The computer name, from the dynamic store with no lookup: Foundation's Host
			// resolves names and can block on DNS on this start path.
			"HOST_NAME": SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "",
			"HOST_LOCAL": localHost.map { $0 + ".local" } ?? "",
		]) { $1 }
	}

	// Public keys only, in both directions (the SSHSetupInstaller reasoning), plus the
	// per-mount hand-off: kind<TAB>name<TAB>hostpath for every enabled sshfs-kind mount.
	static func extraFiles(for config: VMConfig) throws -> [String: Data?] {
		try extraFiles(for: config, lab: .current)
	}

	static func extraFiles(for config: VMConfig, lab: LabEnvironment?) throws -> [String: Data?] {
		let marker = try SSHSetupInstaller.marker(for: config)
		let publicKey = try SSHSetupInstaller.ensureKeypair(for: config, marker: marker)
		// A legacy tag or path with a tab or line break would corrupt the
		// kind<TAB>name<TAB>path list: names are validated at entry, but a broken row is
		// never emitted.
		let sshfsMounts = config.mountPoints
			.filter { $0.enabled && $0.kind == MountKind.sshfs }
			.filter { mount in
				let usable = !NameRule.hasControlCharacters(mount.tag)
					&& !NameRule.hasControlCharacters(mount.path)
				if !usable {
					MachmanLogger.log(.log,
						"\(config.name): mount \(mount.tag.debugDescription) can't be listed "
							+ "for the guest — rename its tag")
				}
				return usable
			}
			.map { "\(MountKind.sshfs)\t\($0.tag)\t\($0.path)" }
		return [
			"host_key.pub": Data((publicKey + "\n").utf8),
			"host_machine_key.pub": machineHostKey(lab: lab),
			GuestSetupInstallerInfo.mountsFileName: sshfsMounts.isEmpty
				? nil : Data((sshfsMounts.joined(separator: "\n") + "\n").utf8),
		]
	}

	// The Mac's sshd host key, which the guest pins for 'ssh mac' and its sshfs mounts. Under
	// a lab sshd (MACHMAN_LAB_SSHD_HOSTKEY) the guest pins the lab's key instead: the lab
	// routes the guest's "Mac" to its own sshd. An unreadable lab key ships no pin at all,
	// never this Mac's.
	static func machineHostKey(
		lab: LabEnvironment?, systemKeyPath: String = "/etc/ssh/ssh_host_ed25519_key.pub"
	) -> Data? {
		guard let labKey = lab?.sshdHostKeyPath else {
			let key = try? String(contentsOfFile: systemKeyPath, encoding: .utf8)
			return key.map { Data($0.utf8) }
		}
		guard let key = try? String(contentsOfFile: labKey, encoding: .utf8),
			!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			MachmanLogger.log(.passiveError, "test mode: no lab sshd host key at \(labKey) "
				+ "\u{2014} the guest gets no Mac host-key pin")
			return nil
		}
		return Data(key.utf8)
	}

	// The guest-writable drop-box: a sibling of the payload dir, so the script addresses
	// it payload-relatively and it rides the same share (or the same sshfs mount).
	static func reportDirectoryURL(for config: VMConfig) -> URL {
		GuestInstallerWriter.payloadDirectory(named: reportDirectoryName, for: config)
	}

	static func reportFilePath(for config: VMConfig) -> String {
		reportDirectoryURL(for: config)
			.appendingPathComponent(GuestSetupInstallerInfo.reportName).path
	}

	// A guest without a virtiofs driver sshfs-mounts the share at boot from the host path in
	// its machman.env, which its fstab or rc.local embeds: <vmdir>/share would strand it at
	// the first rename. It gets a link in the library instead, hidden (no VM) and named by
	// the VM's marker, which a rename keeps: <library>/.machman-shares/<marker> ->
	// ../<vm>/share, re-pointed at every start. ssh.setupSharePath, the BSD guide's by-hand
	// mount, serves the same link once it exists (C26): it carries no VM name either.
	static let shareLinksDirectoryName = ".machman-shares"

	static func shareLinksDirectory(for config: VMConfig) -> URL {
		URL(fileURLWithPath: config.vmDirPath()).deletingLastPathComponent()
			.appendingPathComponent(shareLinksDirectoryName, isDirectory: true)
	}

	// Where the VM's link points: its own share, relative so the library can move.
	private static func shareLinkDestination(for config: VMConfig) -> String {
		"../\(URL(fileURLWithPath: config.vmDirPath()).lastPathComponent)/"
			+ GuestInstallerWriter.payloadRootName
	}

	// The link's path while it points at this VM's share; nil before the first start, or
	// while another VM (an un-reminted copy) holds it.
	static func stableSharePath(for config: VMConfig) -> String? {
		guard let marker = SSHSetupInstaller.existingMarker(for: config) else { return nil }
		let link = shareLinksDirectory(for: config).appendingPathComponent(marker).path
		guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link))
			== shareLinkDestination(for: config) else { return nil }
		return link
	}

	// Points the VM's link at its share (a rename moved it) and sweeps links whose VM
	// directory is gone (deleted, or renamed away by a VM that has not started since).
	// Never mints the marker (a served start's writePayload does, first). Failures are
	// logged: the guest then gets the real path, as before.
	@discardableResult
	static func pointStableShareLink(for config: VMConfig) -> URL? {
		guard let marker = SSHSetupInstaller.existingMarker(for: config) else { return nil }
		let fm = FileManager.default
		let dir = shareLinksDirectory(for: config)
		do {
			try fm.createDirectory(at: dir, withIntermediateDirectories: true)
			for name in try fm.contentsOfDirectory(atPath: dir.path) where name != marker {
				let entry = dir.appendingPathComponent(name)
				guard let target = try? fm.destinationOfSymbolicLink(atPath: entry.path)
				else { continue }
				let vmDir = dir.appendingPathComponent(target).deletingLastPathComponent()
				if !fm.fileExists(atPath: vmDir.standardizedFileURL.path) {
					try? fm.removeItem(at: entry)
				}
			}
			let link = dir.appendingPathComponent(marker)
			let destination = shareLinkDestination(for: config)
			if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != destination {
				try? fm.removeItem(at: link)
				try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
			}
			return link
		} catch {
			MachmanLogger.log(.log,
				"\(config.name): no rename-stable share link — \(error.localizedDescription)")
			return nil
		}
	}

	// The payload dirs this installer supersedes — cleaned up on every write and remove
	// so exactly one served truth exists (an old daemon regenerates them, which is what
	// the 1.0.7 floor prompt exists to stop).
	static let supersededDirectoryNames = [
		ConsoleLoginInstallerInfo.directoryName,
		SSHSetupInfo.directoryName,
		SSHSetupInfo.reportDirectoryName,
	]

	// The two reserved share directories, created EMPTY (superseded/legacy names swept).
	// The VZ share registers these once at start whatever the serve state — serving is a
	// question of content, so toggling never needs live device changes and a non-serving
	// guest mounts an empty pair.
	@discardableResult
	static func ensurePayloadDirectories(
		for config: VMConfig
	) throws -> (payload: URL, report: URL) {
		let fm = FileManager.default
		let report = reportDirectoryURL(for: config)
		try fm.createDirectory(at: report, withIntermediateDirectories: true)
		let payload = GuestInstallerWriter.payloadDirectory(named: directoryName, for: config)
		try fm.createDirectory(at: payload, withIntermediateDirectories: true)
		GuestInstallerWriter.removeLegacyPayload(named: reportDirectoryName, for: config)
		for name in supersededDirectoryNames {
			try? fm.removeItem(at: GuestInstallerWriter.payloadDirectory(
				named: name, for: config))
		}
		// Every start re-pins under the current alias, serving or not: the pin is keyed by
		// the alias, which a rename or a newer default mapping can have moved — and
		// re-points the share link, which a rename moved too.
		SSHSetupInstaller.writeKnownHosts(for: config)
		pointStableShareLink(for: config)
		return (payload, report)
	}

	// The script a VM's payload carries (S67): its pinned entry's, checked against the digest
	// it was stored under — or this build's while it has no pin, or one the store can't serve.
	static func servedScript(
		for config: VMConfig, store: GuestSetupStore = .current
	) -> GuestSetupStore.Script {
		if let id = config.setup?.script, id != store.builtIn.entry.id,
			let entry = store.entry(id: id), let data = store.script(id: id) {
			return GuestSetupStore.Script(data: data, entry: entry)
		}
		return store.builtIn
	}

	// Writes <vmdir>/share/GuestSetup/ (script 0755 + machman.env + mounts.list + public
	// keys) and the empty writable <vmdir>/share/GuestReport/; returns both. Regenerated
	// at every assembly that SERVES (VMConfig.servesSetupPayload).
	@discardableResult
	static func writePayload(
		for config: VMConfig, store: GuestSetupStore = .current
	) throws -> (payload: URL, report: URL) {
		let marker = try SSHSetupInstaller.marker(for: config)
		// Cache the marker for reset-time cleanup (creates the ssh state on first use).
		if config.ssh?.marker != marker {
			var state = config.ssh ?? SSHConfig()
			state.marker = marker
			config.ssh = state
			try config.saveVMConfig()
		}
		let (_, report) = try ensurePayloadDirectories(for: config)
		let script = servedScript(for: config, store: store)
		// This build's script goes into the store as it is first served, so a later build
		// still serves it to the VMs it was served to.
		if script.entry.id == store.builtIn.entry.id {
			store.ensureBuiltIn()
		}
		let payload = try GuestInstallerWriter.write(Self.self, for: config, script: script.data)
		// The alias (and so the pin's key) can have changed while the VM was stopped.
		SSHSetupInstaller.writeKnownHosts(for: config)
		return (payload, report)
	}

	// Drop the share dirs from disk: the device was removed, or vm.setup.reset wiped the
	// report state. Keys and config.ssh/config.setup are the caller's business. The share
	// root goes with its last payload (the next assembly recreates it).
	static func removePayload(for config: VMConfig) {
		let fm = FileManager.default
		for name in [directoryName, reportDirectoryName] + supersededDirectoryNames {
			try? fm.removeItem(at: GuestInstallerWriter.payloadDirectory(
				named: name, for: config))
			GuestInstallerWriter.removeLegacyPayload(named: name, for: config)
		}
		removeEmptyDirectory(GuestInstallerWriter.payloadRoot(for: config).path)
	}
}
