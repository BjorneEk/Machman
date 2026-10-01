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

enum OpenSSHConfigCheck {
	static var available: Bool {
		FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
	}

	// ssh's exit status and its stdout + stderr. Async and detached: the wait blocks its
	// thread, and callers are often @MainActor suites; a blocked main actor starves the
	// in-process stub hosts other suites run in parallel (their hello deadlines are short).
	static func resolve(config: URL, host: String) async throws -> (status: Int32, output: String) {
		try await Task.detached { try run(config: config, host: host) }.value
	}

	private static func run(config: URL, host: String) throws -> (status: Int32, output: String) {
		let ssh = Process()
		ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		ssh.arguments = ["-G", "-F", config.path, host]
		let pipe = Pipe()
		ssh.standardOutput = pipe
		ssh.standardError = pipe
		ssh.standardInput = FileHandle.nullDevice
		try ssh.run()
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		ssh.waitUntilExit()
		return (ssh.terminationStatus, String(decoding: data, as: UTF8.self))
	}
}
