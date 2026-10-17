//
//  Samples+Installs.swift
//  MachmanFixtures
//
//  Two macOS installs at once (Q33): the corner shows their cards in VM-name order.
//

import Foundation
import MachmanAPI

extension Samples {
	// A macOS 15.4 install laying the system down, past half way.
	public static func installingMacInstall(version: String = "15.4") -> InstallPhase {
		InstallPhase(
			kind: .installing, version: version, build: "24E248",
			progress: ProgressInfo(fraction: 0.6))
	}
}
