//
//  RenderSandbox.swift
//  MachmanRender
//
//  The render run's sandbox contract — the test guard's, under a render suite prefix:
//
//    MACHMAN_SUITE_ID   com.gustaffranzen.Machman.render-<token>   token = 3-32 alphanumerics
//    MACHMAN_DATA_DIR   an absolute path containing <token>        stores the scenes persist
//    CFFIXED_USER_HOME  an absolute path containing <token>        defaults, ~/Library
//
//  scripts/render.sh exports it and removes the sandbox afterwards.
//

import Foundation

enum RenderSandbox {
	static let suitePrefix = "com.gustaffranzen.Machman.render-"

	static var dataDir: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACHMAN_DATA_DIR"]
			?? "/var/empty")
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
	}

	private static func refuse(_ why: String) -> Never {
		Console.err("MachmanRender: refusing to run: \(why)")
		Console.err("  Run it through scripts/render.sh.")
		exit(78)
	}
}
