//
//  SSHHostFiles.swift
//  MachmanCore
//
//  The one owner of every ~/.ssh write the daemon makes (PR17): the managed config and its
//  known_hosts, the Include line, and the guest→Mac lines in authorized_keys. Isolated to
//  the router's actor, so no two edits of one file interleave; the file surgery itself is
//  the writer's (SSHHostConfigWriter). The router holds it as `sshFiles`, nil in tests that
//  must never touch ~/.ssh.
//

import Foundation
import MachmanAPI

@MainActor
final class SSHHostFiles {
	let writer: SSHHostConfigWriter

	init(writer: SSHHostConfigWriter) {
		self.writer = writer
	}

	// Rewrites ~/.ssh/machman/config, its known_hosts and the Include line from `entries`.
	func apply(entries: [SSHHostConfigWriter.VMEntry]) throws {
		try writer.apply(entries: entries)
	}

	// Installs the guest's reverse-key line, or removes it (keyLine nil).
	func setReverseKey(_ keyLine: String?, marker: String, vmName: String) throws {
		try writer.setReverseKey(keyLine, marker: marker, vmName: vmName)
	}
}
