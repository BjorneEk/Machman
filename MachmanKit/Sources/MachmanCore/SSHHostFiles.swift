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

	// MARK: - Regeneration (C22)

	// What a pass writes, gathered from current state; nil skips the write.
	typealias EntrySource = @MainActor () async -> [SSHHostConfigWriter.VMEntry]?

	// The pass in flight, whether a request came in during it, and the newest source.
	private var regeneration: Task<Void, Never>?
	private var requestedAgain = false
	private var source: EntrySource?

	// Rewrites ~/.ssh/machman/config, its known_hosts and the Include line from what `source`
	// gathers. One pass at a time, and a request during a pass buys exactly one more, which
	// gathers anew: the last write always reflects state read after the last request. A
	// pass per request let the one that finished last win, so a slow one that started
	// before a delete or an alias change restored the old block.
	func regenerate(from source: @escaping EntrySource) {
		self.source = source
		guard regeneration == nil else {
			requestedAgain = true
			return
		}
		regeneration = Task { [weak self] in
			while let self {
				self.requestedAgain = false
				if let entries = await self.source?() {
					do {
						try self.writer.apply(entries: entries)
					} catch {
						MachmanLogger.log(.passiveError,
							"cannot write ~/.ssh/machman/config: \(error)")
					}
				}
				guard self.requestedAgain else {
					self.regeneration = nil
					return
				}
			}
		}
	}

	// Returns once no pass is running or requested (a test seam).
	func settled() async {
		while let regeneration {
			await regeneration.value
		}
	}

	// MARK: - Reverse access

	// Installs the guest's reverse-key line, or removes it (keyLine nil).
	func setReverseKey(_ keyLine: String?, marker: String, vmName: String) throws {
		try writer.setReverseKey(keyLine, marker: marker, vmName: vmName)
	}
}
