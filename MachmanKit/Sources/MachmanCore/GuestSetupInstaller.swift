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
	static func environment(for config: VMConfig) throws -> [String: String] {
		let localHost = SCDynamicStoreCopyLocalHostName(nil) as String?
		let bootMode: String = {
			switch config.boot {
			case .macOS: return "macos"
			case .linuxKernel: return "kernel"
			default: return "efi"
			}
		}()
		return [
			"VM_NAME": config.name,
			"MARKER": try SSHSetupInstaller.marker(for: config),
			"REPORT_DIR_NAME": reportDirectoryName,
			"MOUNT_ROOT": GuestPaths.mounts,
			// Where the guest mounts the share: macOS automounts it under My Shared Files.
			"SHARE_ROOT": bootMode == "macos" ? GuestPaths.macOSAutomount : GuestPaths.share,
			"SHARE_TAG": GuestPaths.shareTag,
			"SHARE_HOST_PATH": GuestInstallerWriter.payloadRoot(for: config).path,
			"BOOT_MODE": bootMode,
			"CONSOLE_COUNT": String(config.consolePorts.filter(\.enabled).count),
			"UART_COUNT": String(config.uartPorts.filter(\.enabled).count),
			"HOST_USER": NSUserName(),
			"HOST_NAME": Host.current().localizedName ?? "",
			"HOST_LOCAL": localHost.map { $0 + ".local" } ?? "",
		]
	}

	// Public keys only, in both directions (the SSHSetupInstaller reasoning), plus the
	// per-mount hand-off: kind<TAB>name<TAB>hostpath for every enabled sshfs-kind mount.
	static func extraFiles(for config: VMConfig) throws -> [String: Data?] {
		let marker = try SSHSetupInstaller.marker(for: config)
		let publicKey = try SSHSetupInstaller.ensureKeypair(for: config, marker: marker)
		let machineKey = try? String(
			contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8)
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
			"host_machine_key.pub": machineKey.map { Data($0.utf8) },
			GuestSetupInstallerInfo.mountsFileName: sshfsMounts.isEmpty
				? nil : Data((sshfsMounts.joined(separator: "\n") + "\n").utf8),
		]
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
		// the alias, which a rename or a newer default mapping can have moved.
		SSHSetupInstaller.writeKnownHosts(for: config)
		return (payload, report)
	}

	// Writes <vmdir>/share/GuestSetup/ (script 0755 + machman.env + mounts.list + public
	// keys) and the empty writable <vmdir>/share/GuestReport/; returns both. Regenerated
	// at every assembly that SERVES (VMConfig.servesSetupPayload).
	@discardableResult
	static func writePayload(for config: VMConfig) throws -> (payload: URL, report: URL) {
		let marker = try SSHSetupInstaller.marker(for: config)
		// Cache the marker for reset-time cleanup (creates the ssh state on first use).
		if config.ssh?.marker != marker {
			var state = config.ssh ?? SSHConfig()
			state.marker = marker
			config.ssh = state
			try config.saveVMConfig()
		}
		let (_, report) = try ensurePayloadDirectories(for: config)
		let payload = try GuestInstallerWriter.write(Self.self, for: config)
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
