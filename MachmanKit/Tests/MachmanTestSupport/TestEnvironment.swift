//
//  TestEnvironment.swift
//  MachmanTestSupport
//
//  The per-run sandbox every MachmanKit test runs inside (exported by scripts/test.sh and
//  enforced at load time by MachmanTestGuard). Tests get their scratch space here — never
//  from NSTemporaryDirectory()/FileManager.temporaryDirectory, which is the real per-user
//  temp dir and outlives a crashed run. Everything below is removed when the run ends.
//
//  The first touch of any sandbox member (suiteID, token, dataDir, homeDir, scratch) validates
//  the whole contract — the one guard.c checks — and fatalErrors on a violation, so a guard
//  that is ever unlinked or neutered still fails closed before a test can write outside the
//  run's sandbox. Keep the two in step.
//

import Foundation

public enum TestEnvironment {
	public static let suitePrefix = "com.gustaffranzen.Machman.test-"

	// com.gustaffranzen.Machman.test-<token>: the suite every MachmanPaths lookup resolves to.
	public static var suiteID: String { sandbox.suiteID }

	public static var token: String { sandbox.token }

	// The run's library root (MACHMAN_DATA_DIR): <run>/data. machmanVMDir = <dataDir>/VMs.
	public static var dataDir: String { sandbox.dataDir }

	// The run's fake home (CFFIXED_USER_HOME): NSHomeDirectory(), ~/.ssh, ~/Library/...
	public static var homeDir: String { sandbox.homeDir }

	// Per-run scratch, with a trailing slash — the drop-in shape of NSTemporaryDirectory().
	// Short on purpose: socket paths built on it must stay under sun_path's 104 bytes.
	public static let scratch: String = {
		let path = sandbox.dataDir + "/scratch/"
		try? FileManager.default.createDirectory(
			atPath: path, withIntermediateDirectories: true)
		return path
	}()

	public static var scratchURL: URL { URL(fileURLWithPath: scratch, isDirectory: true) }

	// A fresh path in scratch for a socket, or for the base of a test's socket names:
	// "<prefix>-<UUID><suffix>". Tests used to name them by pid plus a random number below
	// 99,999, which lets two tests draw the same path (Q7); a UUID can't. Keep prefixes to
	// about 20 bytes: sun_path holds 103, and scratch plus a UUID already takes about 70.
	public static func socketPath(_ prefix: String, suffix: String = ".sock") -> String {
		scratch + "\(prefix)-\(UUID().uuidString)\(suffix)"
	}

	private struct Sandbox {
		let suiteID: String
		let token: String
		let dataDir: String
		let homeDir: String
	}

	private static let sandbox: Sandbox = {
		let suiteID = environment("MACHMAN_SUITE_ID")
		guard suiteID.hasPrefix(suitePrefix) else {
			refuse("MACHMAN_SUITE_ID '\(suiteID)' is not a per-run test suite id")
		}
		let token = String(suiteID.dropFirst(suitePrefix.count))
		guard (3...32).contains(token.count),
			token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
		else {
			refuse("the MACHMAN_SUITE_ID token '\(token)' must be 3-32 alphanumerics")
		}
		return Sandbox(
			suiteID: suiteID, token: token,
			dataDir: pathWithToken("MACHMAN_DATA_DIR", token),
			homeDir: pathWithToken("CFFIXED_USER_HOME", token))
	}()

	private static func environment(_ name: String) -> String {
		guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
			refuse("\(name) is unset")
		}
		return value
	}

	// An absolute path containing the run token: one that cannot be a real library or home.
	private static func pathWithToken(_ name: String, _ token: String) -> String {
		let value = environment(name)
		guard value.hasPrefix("/"), value.contains(token) else {
			refuse("\(name) must be an absolute path containing the run token '\(token)' "
				+ "(got '\(value)')")
		}
		return value
	}

	private static func refuse(_ why: String) -> Never {
		// Unreachable behind MachmanTestGuard; a loud backstop if the guard is ever unlinked.
		fatalError("TestEnvironment: \(why) — run the tests through scripts/test.sh")
	}
}
