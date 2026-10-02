//
//  VMHostVersion.swift
//  MachmanCore
//
//  The version a vmhost answers machman.hello with (as "<version>-vmhost"): its OWN bundle
//  version — never the spawning daemon's. That daemon may be older or newer than the binary it
//  launched, and launchd passes nothing at all, so a launch-agent host used to report "dev".
//  The daemon reads the value to tell a vmhost that outlived an update (E22).
//

import Foundation

public enum VMHostVersion {
	// The bundle's CFBundleShortVersionString; else MACHMAN_VERSION (an unversioned build
	// spawned by a daemon); else "dev", which every versioned daemon counts as older.
	public static func current(
		bundleInfo: [String: Any]? = Bundle.main.infoDictionary,
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> String {
		if let version = bundleInfo?["CFBundleShortVersionString"] as? String, !version.isEmpty {
			return version
		}
		return environment["MACHMAN_VERSION"] ?? "dev"
	}
}
