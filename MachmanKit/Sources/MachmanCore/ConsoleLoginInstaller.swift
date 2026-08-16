//
//  ConsoleLoginInstaller.swift
//  MachmanCore
//
//  The macOS-guest login installer payload: one self-contained POSIX script (launchd
//  plists embedded as heredocs) that installs a getty login prompt for each Machman
//  console — the measured recipe: /etc/ttys getty lines are dead on modern macOS, a
//  LaunchDaemon running /usr/libexec/getty with KeepAlive shows a prompt immediately and
//  survives reboots. The payload is regenerated at every assembly so it always matches
//  the enabled console set (the port list rides machman.env, never the script text), and
//  is served to the guest read-only as the reserved "LoginInstaller" directory inside the
//  automounting share (VMDevices) — it appears at /Volumes/My Shared Files/LoginInstaller
//  next to the VM's regular mounts.
//

import Foundation
import MachmanAPI

enum ConsoleLoginInstaller: GuestInstallerPayload {
	// One name everywhere: the on-disk payload directory under the VM AND the directory
	// the guest sees inside the automounting share.
	static let directoryName = ConsoleLoginInstallerInfo.directoryName
	static let scriptName = ConsoleLoginInstallerInfo.scriptName

	// The enabled console ports' macOS device names in compacted order — exactly the
	// numbering the guest sees at the next boot (and the wire serves as guestIndex).
	static func ports(for config: VMConfig) -> [String] {
		(0..<config.consolePorts.filter(\.enabled).count).map {
			SerialPortKind.console.guestDevice(index: $0, os: .macOS)
		}
	}

	static func environment(for config: VMConfig) throws -> [String: String] {
		[
			"VM_NAME": config.name,
			"PORTS": ports(for: config).joined(separator: " "),
		]
	}

	// Writes <vmdir>/share/LoginInstaller/ (script 0755 + machman.env), returns the dir.
	@discardableResult
	static func writePayload(for config: VMConfig) throws -> URL {
		try GuestInstallerWriter.write(Self.self, for: config)
	}

	// The whole installer — GuestScripts/console-login.sh, embedded at build time.
	// Idempotent: every run first removes all Machman console logins (cleaning up ports
	// that no longer exist), then installs the current set.
	static var script: EmbeddedScript {
		EmbeddedScript(bytes: PackageResources.console_login_sh)
	}
}
