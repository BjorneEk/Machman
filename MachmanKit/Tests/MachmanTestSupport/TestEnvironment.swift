//
//  TestEnvironment.swift
//  MachmanTestSupport
//
//  The per-run sandbox every MachmanKit test runs inside (exported by scripts/test.sh and
//  enforced at load time by MachmanTestGuard). Tests get their scratch space here — never
//  from NSTemporaryDirectory()/FileManager.temporaryDirectory, which is the real per-user
//  temp dir and outlives a crashed run. Everything below is removed when the run ends.
//

import Foundation

public enum TestEnvironment {
	public static let suitePrefix = "com.gustaffranzen.Machman.test-"

	// com.gustaffranzen.Machman.test-<token>: the suite every MachmanPaths lookup resolves to.
	public static let suiteID: String = requiredEnv("MACHMAN_SUITE_ID")

	public static let token: String = String(suiteID.dropFirst(suitePrefix.count))

	// The run's library root (MACHMAN_DATA_DIR): <run>/data. machmanVMDir = <dataDir>/VMs.
	public static let dataDir: String = requiredEnv("MACHMAN_DATA_DIR")

	// The run's fake home (CFFIXED_USER_HOME): NSHomeDirectory(), ~/.ssh, ~/Library/...
	public static let homeDir: String = requiredEnv("CFFIXED_USER_HOME")

	// Per-run scratch, with a trailing slash — the drop-in shape of NSTemporaryDirectory().
	// Short on purpose: socket paths built on it must stay under sun_path's 104 bytes.
	public static let scratch: String = {
		let path = dataDir + "/scratch/"
		try? FileManager.default.createDirectory(
			atPath: path, withIntermediateDirectories: true)
		return path
	}()

	public static var scratchURL: URL { URL(fileURLWithPath: scratch, isDirectory: true) }

	private static func requiredEnv(_ name: String) -> String {
		guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
			// Unreachable behind MachmanTestGuard; a loud backstop if the guard is ever unlinked.
			fatalError("\(name) is unset — run the tests through scripts/test.sh")
		}
		return value
	}
}
