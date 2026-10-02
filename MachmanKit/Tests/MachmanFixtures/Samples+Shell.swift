//
//  Samples+Shell.swift
//  MachmanFixtures
//
//  Lane 4d's samples: the shell's progress, canvas and toast states.
//

import Foundation
import MachmanAPI

extension Samples {
	// A macOS 15.4 download a quarter done after two minutes: 4 of 16 GB, about 6 min left.
	public static func downloadingMacInstall(version: String = "15.4") -> InstallPhase {
		InstallPhase(
			kind: .downloading, version: version, build: "24E248",
			progress: ProgressInfo(
				fraction: 0.25, completedBytes: 4 << 30, totalBytes: 16 << 30),
			downloadStartedAt: now.addingTimeInterval(-120))
	}
}
