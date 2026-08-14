//
//  ConsoleLoginInstaller.swift
//  MachmanCore
//
//  The macOS-guest login installer payload: one self-contained POSIX script (launchd
//  plists embedded as heredocs) that installs a getty login prompt for each Machman
//  console — the measured recipe: /etc/ttys getty lines are dead on modern macOS, a
//  LaunchDaemon running /usr/libexec/getty with KeepAlive shows a prompt immediately and
//  survives reboots. The payload is regenerated at every assembly so it always matches
//  the enabled console set, and is served to the guest read-only as the reserved
//  "LoginInstaller" directory inside the automounting share (VMDevices) — it appears at
//  /Volumes/My Shared Files/LoginInstaller next to the VM's regular mounts.
//

import Foundation
import MachmanAPI

enum ConsoleLoginInstaller {
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

	// Writes <vmdir>/login-installer/install.sh (0755) and returns the directory URL.
	static func writePayload(for config: VMConfig) throws -> URL {
		let dir = config.localURL(file: directoryName)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let scriptURL = dir.appendingPathComponent(scriptName)
		try script(vmName: config.name, ports: ports(for: config))
			.write(to: scriptURL, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
		return dir
	}

	// The whole installer. Idempotent: every run first removes all Machman console
	// logins (cleans up ports that no longer exist), then installs the current set.
	static func script(vmName: String, ports: [String]) -> String {
		#"""
		#!/bin/sh
		# Machman console login installer — generated for "\#(vmName)". Do not edit:
		# Machman regenerates this file at every VM start to match the attached consoles.
		#
		# Installs a login prompt (launchd getty) for each Machman console. Safe to
		# re-run at any time; run with --uninstall to remove everything it installed.
		set -eu

		PORTS="\#(ports.joined(separator: " "))"
		PREFIX="com.machman.console-getty"
		DAEMONS="/Library/LaunchDaemons"

		if [ "$(id -u)" -ne 0 ]; then
			echo "Please run with sudo:  sudo sh \"$0\" ${1:-}" >&2
			exit 1
		fi

		remove_all() {
			for plist in "$DAEMONS/$PREFIX".*.plist; do
				[ -e "$plist" ] || continue
				label="$(basename "$plist" .plist)"
				launchctl bootout "system/$label" 2>/dev/null || true
				rm -f "$plist"
				echo "removed $label"
			done
		}

		if [ "${1:-}" = "--uninstall" ]; then
			remove_all
			echo "done — all Machman console logins removed."
			exit 0
		fi

		if [ -z "$PORTS" ]; then
			echo "This VM has no consoles attached — add one in Machman first."
			exit 0
		fi

		# Clean slate: drop logins for consoles that were removed, then install the set.
		remove_all >/dev/null

		i=0
		installed=0
		for port in $PORTS; do
			if [ ! -e "/dev/$port" ]; then
				echo "warning: /dev/$port is not present in this guest — skipped" >&2
				i=$((i + 1))
				continue
			fi
			plist="$DAEMONS/$PREFIX.$i.plist"
			cat > "$plist" <<PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
		  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>Label</key>
			<string>$PREFIX.$i</string>
			<key>ProgramArguments</key>
			<array>
				<string>/usr/libexec/getty</string>
				<string>std.115200</string>
				<string>$port</string>
			</array>
			<key>KeepAlive</key>
			<true/>
		</dict>
		</plist>
		PLIST
			chown root:wheel "$plist"
			chmod 644 "$plist"
			launchctl bootstrap system "$plist"
			echo "installed login on /dev/$port"
			installed=$((installed + 1))
			i=$((i + 1))
		done
		echo "done — $installed of \#(ports.count) console login(s) active." \
			"Prompts appear in the Machman consoles immediately."
		"""#
	}
}
