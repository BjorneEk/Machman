//
//  SSHCommand.swift
//  MachmanDesktopCore
//
//  argv for /usr/bin/ssh from daemon-served state — self-contained (-i + IdentitiesOnly),
//  deliberately independent of the ~/.ssh integration so tabs work without consent. Pure
//  argument building, so the session tabs, the tree and the session inspector all start the
//  same command and a test can pin it.
//

import Foundation
import MachmanAPI

// Host verification uses the VM's OWN known-hosts file, keyed by its alias: the app never
// writes the user's ~/.ssh (which is the promise the setup guide makes), the pin follows
// the guest rather than its address, and a guest whose key we already know is verified
// strictly. Keepalives matter because a guest that dies mid-session otherwise leaves the
// tab hanging with no output and no exit.
public enum SSHCommand {
	public static func arguments(for vm: VMInfo) -> [String]? {
		guard let ssh = vm.ssh, let user = ssh.guestUser, let address = ssh.address,
			let identity = ssh.identityFilePath else { return nil }
		var arguments = [
			"-i", identity,
			"-o", "IdentitiesOnly=yes",
			"-o", "ConnectTimeout=10",
			"-o", "ServerAliveInterval=15",
			"-o", "ServerAliveCountMax=3",
		]
		// Strict checking only when there is a pin to check against: the daemon serves
		// knownHostsPath once the file actually exists, and a host key means we know who
		// should answer. Otherwise accept-new — better than a TOFU prompt in a terminal
		// the user did not ask to be prompted in, and it cannot lock them out.
		if let knownHosts = ssh.knownHostsPath, ssh.guestHostKey != nil {
			arguments += [
				"-o", quotedOption("UserKnownHostsFile", path: knownHosts),
				"-o", "HostKeyAlias=\(hostKeyAlias(for: vm))",
				"-o", "StrictHostKeyChecking=yes",
			]
		} else {
			arguments += ["-o", "StrictHostKeyChecking=accept-new"]
		}
		return arguments + ["\(user)@\(address)"]
	}

	// The same connection as one line to paste into a terminal: self-contained, so it works
	// without the ~/.ssh integration. The key path carries the VM's name, so it goes in
	// quoted (C26).
	public static func shellLine(for vm: VMInfo) -> String? {
		guard let ssh = vm.ssh, let user = ssh.guestUser, let address = ssh.address,
			let identity = ssh.identityFilePath else { return nil }
		return "ssh -i \(ShellQuote.single(identity)) -o IdentitiesOnly=yes \(user)@\(address)"
	}

	// The name the VM's pin is keyed by. The daemon serves it; the fallback is for older
	// daemons and uses the daemon's own rule — the bare VM name (a space ends the word for
	// ssh) or an unmapped "<vm>.machman" would never match the pin.
	public static func hostKeyAlias(for vm: VMInfo) -> String {
		if let alias = vm.ssh?.alias, SSHAliasRule.isWellFormed(alias) { return alias }
		return SSHAliasRule.defaultAlias(for: vm.name)
	}

	// ssh parses -o values with its own config parser, and UserKnownHostsFile takes a
	// SPACE-SEPARATED LIST — so an unquoted path under "Application Support" becomes three
	// filenames that do not exist, and strict checking then fails with "no host key is
	// known" (measured). Quoting inside the value is what ssh_config expects.
	private static func quotedOption(_ key: String, path: String) -> String {
		"\(key)=\"\(path)\""
	}
}
