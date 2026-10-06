//
//  SSHPublicKey.swift
//  MachmanDesktopCore
//
//  This Mac's public key for one VM (P11): the `.pub` beside the identity file the daemon
//  serves, read off the main actor, once per inspector and key path. It used to be read in
//  the SSH inspector's body, on the main actor at every render.
//

import Foundation

public enum SSHPublicKey {
	// The key line, trimmed; nil when the file is missing, unreadable or empty.
	public static func read(identityPath: String) async -> String? {
		await Task.detached(priority: .utility) {
			let line = (try? String(contentsOfFile: identityPath + ".pub", encoding: .utf8))?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			return line?.isEmpty == false ? line : nil
		}.value
	}
}
