//
//  OpenSSHConfigCheck.swift
//  MachmanCoreTests
//
//  Asks the system's OpenSSH whether a generated config parses: `ssh -G -F <file> <host>`
//  prints the configuration it would use for <host> and exits without connecting, and -F
//  makes it read only that file (never ~/.ssh/config or /etc/ssh). One bad line makes ssh
//  refuse every host, which is exactly the failure the managed file must never cause.
//  Tests using it are skipped where /usr/bin/ssh is absent; hosts are *.invalid or
//  aliases from the file, and nothing is ever resolved or contacted.
//

import Foundation
import MachmanTestSupport

enum OpenSSHConfigCheck {
	static var available: Bool {
		FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
	}

	// ssh's exit status and its stdout + stderr, through Subprocess: the wait holds no Swift
	// concurrency thread, and callers are often @MainActor suites.
	static func resolve(config: URL, host: String) async throws -> (status: Int32, output: String) {
		let ssh = try await Subprocess.run("/usr/bin/ssh", ["-G", "-F", config.path, host])
		return (ssh.status, ssh.output)
	}
}
