//
//  MachmanPaths.swift
//  MachmanAPI
//
//  Where Machman lives on this machine. In MachmanAPI (not the engine) because clients need the
//  same resolution to find the daemon's socket without linking MachmanCore.
//
//  Everything hangs off the SUITE IDENTIFIER, not the process's own bundle id: the GUI, the
//  menu-bar agent and the vmhost are separate app bundles that must agree on one library.
//  Each bundle id IS the suite id plus (for helpers) a known suffix — `PRODUCT_BUNDLE_IDENTIFIER
//  = $(MACHMAN_SUITE_ID)[.suffix]`, where the suite is `com.gustaffranzen.Machman` in Release
//  and `com.gustaffranzen.Machman.dev` in Debug. That one difference is what keeps a
//  development build off the production library — there is no runtime guard, because there is
//  nothing left to guard against.
//
//  Two roots, deliberately separate:
//
//    data     ~/Library/Application Support/<suite>/     big, relocatable, backed up (minus disks)
//    runtime  $TMPDIR/<suite>/                           sockets; per-user, cleared on reboot
//
//  Sockets must NOT live under the data dir. sun_path is 104 bytes, and a per-VM socket under a
//  Library-rooted path blows it with a moderately long VM name; a data dir relocated to exFAT or
//  a network mount cannot hold a socket at all.
//

import Foundation

public enum MachmanPaths {

	// MARK: - Identity

	static let fallbackSuiteIdentifier = "com.gustaffranzen.Machman"

	// Helper bundle ids are the suite id plus one of these. Xcode only honours a fixed allowlist
	// of INFOPLIST_KEY_* settings, so a custom "suite id" plist key is silently dropped — the
	// relationship has to be expressed in the identifiers themselves.
	static let helperSuffixes = [".agent", ".vmhost", ".tests", ".uitests"]

	// The identifier every Machman process shares, so the GUI, the menu-bar agent and the
	// vmhost all resolve to ONE library. The env var stays as a tests-and-scripts override
	// (the smoke script exports it); every shipping process resolves from its own bundle id.
	public static func suiteIdentifier(
		env: [String: String] = ProcessInfo.processInfo.environment,
		bundle: Bundle = .main
	) -> String {
		if let id = env["MACHMAN_SUITE_ID"], !id.isEmpty {
			return id
		}
		if let id = bundle.bundleIdentifier, !id.isEmpty {
			return suiteIdentifier(fromBundleID: id)
		}
		return fallbackSuiteIdentifier
	}

	public static func suiteIdentifier(fromBundleID id: String) -> String {
		for suffix in helperSuffixes where id.hasSuffix(suffix) {
			return String(id.dropLast(suffix.count))
		}
		return id
	}

	// MARK: - Data

	// Resolution order:
	//   1. MACHMAN_DATA_DIR — tests and scripts only; not used by any shipping launch path
	//   2. UserDefaults "MachmanDataDir" — the user's chosen library location (external disk etc.)
	//   3. ~/Library/Application Support/<suite>
	public static func dataDir(
		env: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard,
		bundle: Bundle = .main
	) -> String {
		if let dir = env["MACHMAN_DATA_DIR"], !dir.isEmpty {
			return dir
		}
		if let dir = defaults.string(forKey: "MachmanDataDir"), !dir.isEmpty {
			return dir
		}
		return defaultDataDir(env: env, bundle: bundle)
	}

	public static func defaultDataDir(
		env: [String: String] = ProcessInfo.processInfo.environment,
		bundle: Bundle = .main
	) -> String {
		let root = NSSearchPathForDirectoriesInDomains(
			.applicationSupportDirectory, .userDomainMask, true).first
			?? (NSHomeDirectory() + "/Library/Application Support")
		return root + "/" + suiteIdentifier(env: env, bundle: bundle)
	}

	// The VM library. A subdirectory of the data dir so logs, caches and downloaded restore
	// images can sit beside it without the registry scan mistaking them for VMs.
	public static func vmsDir(dataDir: String) -> String {
		dataDir + "/VMs"
	}

	// Safe-run shadows: a SIBLING of the VMs dir, so a shadow and the library share a volume
	// under every override (promotion is one atomic rename) while staying outside the scan.
	public static func safeRunsDir(dataDir: String) -> String {
		dataDir + "/safe"
	}

	public static func vmsDir(
		env: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard,
		bundle: Bundle = .main
	) -> String {
		vmsDir(dataDir: dataDir(env: env, defaults: defaults, bundle: bundle))
	}

	// MARK: - Runtime

	// Sockets and other transient per-boot state. NSTemporaryDirectory() is the per-user
	// darwin temp dir (~49 chars here), which leaves room under the 104-byte sun_path limit.
	public static func runtimeDir(
		env: [String: String] = ProcessInfo.processInfo.environment,
		bundle: Bundle = .main
	) -> String {
		var tmp = NSTemporaryDirectory()
		if tmp.hasSuffix("/") {
			tmp.removeLast()
		}
		return tmp + "/" + suiteIdentifier(env: env, bundle: bundle)
	}

	public static func daemonSocketPath(
		env: [String: String] = ProcessInfo.processInfo.environment,
		bundle: Bundle = .main
	) -> String {
		runtimeDir(env: env, bundle: bundle) + "/machman.sock"
	}

	// Named by a hash of the VM name, not the name itself: a VM may be called anything, and the
	// path has a hard 104-byte ceiling it would otherwise be able to exceed.
	public static func vmSocketPath(vm name: String, bundle: Bundle = .main) -> String {
		vmSocketPath(vm: name, runtimeDir: runtimeDir(bundle: bundle))
	}

	public static func vmSocketPath(vm name: String, runtimeDir: String) -> String {
		"\(runtimeDir)/vm-\(shortHash(name)).sock"
	}

	// FNV-1a, truncated to 32 bits. Hand-rolled to keep this module Foundation-only, and stable
	// across processes and launches (unlike Hasher, which is seeded per process). Public
	// because launch-agent labels reuse it for names launchd cannot carry verbatim.
	public static func shortHash(_ string: String) -> String {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in string.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x0000_0100_0000_01b3
		}
		return String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
	}
}
