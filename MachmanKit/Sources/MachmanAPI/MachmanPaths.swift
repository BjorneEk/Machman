//
//  MachmanPaths.swift
//  MachmanAPI
//
//  Where Machman lives on this machine. In MachmanAPI (not the engine) because clients need
//  the same resolution to find the daemon's socket without linking MachmanCore.
//
//  Data dir resolution order:
//    1. MACHMAN_DATA_DIR environment variable (Xcode scheme, scripts, tests)
//    2. UserDefaults key "MachmanDataDir" (per-bundle-id, machine-local; covers Finder/
//       Spotlight launches, where env vars don't apply)
//    3. ~/.machman (the production default)
//
//  The daemon's socket lives INSIDE the data dir, so a dev daemon and a production daemon can
//  never cross-talk.
//

import Foundation

public enum MachmanPaths {
	public static func dataDir(
		env: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> String {
		if let dir = env["MACHMAN_DATA_DIR"], !dir.isEmpty {
			return dir
		}
		if let dir = defaults.string(forKey: "MachmanDataDir"), !dir.isEmpty {
			return dir
		}
		return NSHomeDirectory() + "/.machman"
	}

	public static func socketPath(dataDir: String) -> String {
		dataDir + "/machman.sock"
	}

	public static func socketPath(
		env: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> String {
		socketPath(dataDir: dataDir(env: env, defaults: defaults))
	}
}
