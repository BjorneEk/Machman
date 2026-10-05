//
//  Lab.swift
//  MachmanLabTests
//
//  The run scripts/lab.sh prepared, as the tests see it. Every lab suite is
//  `.enabled(if: Lab.runs(<tier>))`: a suite never gates on "a lab run exists" alone, so
//  `lab.sh --quick` boots no QEMU guest and `test.sh` (which skips this target) runs nothing.
//

import Foundation
import MachmanTestSupport

enum Lab {
	// What a lab run covers; lab.sh selects tiers per mode (MACHMAN_LAB_TIERS).
	enum Tier: String, CaseIterable, Sendable {
		case harness, smoke, l2, l3, launchd
	}

	static let environment = ProcessInfo.processInfo.environment

	// "harness, smoke,bogus,,l3" -> [.harness, .smoke, .l3]: unknown and empty items drop.
	static func tiers(from value: String?) -> Set<Tier> {
		guard let value else { return [] }
		return Set(value.split(separator: ",").compactMap {
			Tier(rawValue: $0.trimmingCharacters(in: .whitespaces))
		})
	}

	// Active only inside the run sandbox lab.sh minted: the flag AND a run dir named after
	// this process's own token (so a stray MACHMAN_LAB=1 in a test.sh run is not a lab).
	static func isActive(environment: [String: String], token: String) -> Bool {
		environment["MACHMAN_LAB"] == "1" && environment["MACHMAN_LAB_RUN"] == "/tmp/mml.\(token)"
	}

	static var isActive: Bool { isActive(environment: environment, token: TestEnvironment.token) }

	static var tiers: Set<Tier> { tiers(from: environment["MACHMAN_LAB_TIERS"]) }

	static func runs(_ tier: Tier) -> Bool { isActive && tiers.contains(tier) }

	// Whether the built agent and vmhost carry r3-tb's test-mode seams (lab.sh checked).
	static var seamsPresent: Bool { environment["MACHMAN_LAB_SEAMS"] == "1" }

	static var runDir: String { environment["MACHMAN_LAB_RUN"] ?? "" }
	static var cacheDir: String { environment["MACHMAN_LAB_CACHE"] ?? "" }
	static var productsDir: String { environment["MACHMAN_LAB_PRODUCTS"] ?? "" }
	static var repoRoot: String { environment["MACHMAN_LAB_REPO"] ?? "" }
	static var logPath: String { environment["MACHMAN_LAB_LOG"] ?? "" }

	static var pidsDir: String { runDir + "/pids" }
	static var transcriptsDir: String { runDir + "/transcripts" }
	static var scopesDir: String { runDir + "/scopes" }

	static var suiteID: String { TestEnvironment.suiteID }
	static var token: String { TestEnvironment.token }
}
