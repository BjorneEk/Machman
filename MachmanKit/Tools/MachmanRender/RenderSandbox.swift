//
//  RenderSandbox.swift
//  MachmanRender
//
//  The render run's sandbox contract — the test guard's, under a render suite prefix:
//
//    MACHMAN_SUITE_ID   com.gustaffranzen.Machman.render-<token>   token = 3-32 alphanumerics
//    MACHMAN_DATA_DIR   an absolute path containing <token>        stores the scenes persist
//    CFFIXED_USER_HOME  an absolute path containing <token>        paths built from the home
//
//  scripts/render.sh exports it and removes the sandbox afterwards.
//
//  Defaults are the exception: cfprefsd serves them from the REAL home whatever
//  CFFIXED_USER_HOME says. A suite domain is unique to its run (render.sh deletes it), but the
//  tool's own standard domain (its process name, MachmanRender) is the same for every run of
//  every lane, and it is what the views' @AppStorage and UserDefaults.standard reads see. So
//  renders are reproducible only while it is empty: the tool refuses to start while it holds
//  anything, and a run that leaves something there fails. Scenes never write
//  UserDefaults.standard, and nobody runs `defaults write MachmanRender`.
//

import Foundation

enum RenderSandbox {
	static let suitePrefix = "com.gustaffranzen.Machman.render-"

	static var dataDir: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACHMAN_DATA_DIR"]
			?? "/var/empty")
	}

	// UserDefaults.standard's persistent domain: an unbundled tool's is its process name.
	static var standardDomain: String {
		Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
	}

	// What that domain holds in the real home, key names only; empty is the contract.
	static func standardDomainKeys() -> [String] {
		(UserDefaults.standard.persistentDomain(forName: standardDomain) ?? [:]).keys.sorted()
	}

	static func enforce() {
		let env = ProcessInfo.processInfo.environment
		let suite = env["MACHMAN_SUITE_ID"] ?? ""
		guard suite.hasPrefix(suitePrefix) else {
			refuse("MACHMAN_SUITE_ID '\(suite)' is not a render suite id")
		}
		let token = String(suite.dropFirst(suitePrefix.count))
		guard (3...32).contains(token.count),
			token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
		else {
			refuse("the MACHMAN_SUITE_ID token '\(token)' must be 3-32 alphanumerics")
		}
		for name in ["MACHMAN_DATA_DIR", "CFFIXED_USER_HOME"] {
			let value = env[name] ?? ""
			guard value.hasPrefix("/"), value.contains(token) else {
				refuse("\(name) must be an absolute path containing '\(token)' (got '\(value)')")
			}
		}
		let leftovers = standardDomainKeys()
		guard leftovers.isEmpty else {
			refuse(
				"the real home's '\(standardDomain)' defaults domain holds "
					+ "\(leftovers.joined(separator: ", ")), which the scenes would read",
				hint: "Check nothing still needs it, then: defaults delete \(standardDomain)")
		}
	}

	private static func refuse(
		_ why: String, hint: String = "Run it through scripts/render.sh."
	) -> Never {
		Console.err("MachmanRender: refusing to run: \(why)")
		Console.err("  \(hint)")
		exit(78)
	}
}
