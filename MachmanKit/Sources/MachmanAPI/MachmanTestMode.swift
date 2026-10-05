//
//  MachmanTestMode.swift
//  MachmanAPI
//
//  The one predicate behind every test-only seam in product code. Test mode is on only in a
//  Debug build AND under a per-run test suite, com.gustaffranzen.Machman.test-<token>: the
//  suite scripts/test.sh and the lab (scripts/lab.sh) launch everything under. The .dev
//  suite, the Release suite and every Release build are never in test mode, so the seams
//  below change nothing a person runs. Note that a headless test.sh run is itself under test
//  mode: every seam is live in the unit tests, and each takes its LabEnvironment as an
//  argument so a test can prove both sides.
//
//  The lab's variables (MACHMAN_LAB_*) are read only through LabEnvironment, and only under
//  test mode: `LabEnvironment.current` is nil everywhere else.
//

import Foundation

public enum MachmanTestMode {
	public static let suitePrefix = "com.gustaffranzen.Machman.test-"

	// The exact prefix, then a non-empty token of ASCII letters and digits, and nothing more.
	public static func isTestSuite(_ suiteID: String) -> Bool {
		guard suiteID.hasPrefix(suitePrefix) else { return false }
		let token = suiteID.dropFirst(suitePrefix.count)
		return !token.isEmpty && token.unicodeScalars.allSatisfy {
			$0.isASCII && CharacterSet.alphanumerics.contains($0)
		}
	}

	#if DEBUG
	public static let isDebugBuild = true
	#else
	public static let isDebugBuild = false
	#endif

	public static func isActive(suiteID: String, debugBuild: Bool) -> Bool {
		debugBuild && isTestSuite(suiteID)
	}

	// This process's answer, fixed at first use: the suite never changes after launch.
	#if DEBUG
	public static var isActive: Bool { activeInThisProcess }
	private static let activeInThisProcess = isTestSuite(MachmanPaths.suiteIdentifier())
	#else
	public static var isActive: Bool { false }
	#endif
}

// What the lab asked of this process, read once from its environment. nil (the `current` of
// every process outside test mode) means: behave exactly as a person's Machman does.
public struct LabEnvironment: Equatable, Sendable {
	public let suiteID: String
	// The suite's token: the lab's sandbox (/tmp/mml.<token>) is named by it.
	public let token: String
	// MACHMAN_LAB_ANSWERS: the JSON file prompts are answered from (LabAnswers).
	public let answersPath: String?
	// MACHMAN_LAB_SSHD_HOSTKEY: the lab sshd's public host key, pinned in guests in place of
	// this Mac's.
	public let sshdHostKeyPath: String?
	// MACHMAN_LAB_DEVICES: opt-ins to devices the lab otherwise drops (LabDevicePolicy).
	public let deviceOptIns: Set<String>
	// MACHMAN_LAB_AGENT_CONTROL: the agent's lab control socket (LabCommand).
	public let agentControlPath: String?
	// What a vmhost or autostart job of this suite inherits.
	public let forwardedVariables: [String: String]

	public static let labPrefix = "MACHMAN_LAB_"

	// nil unless (suiteID, debugBuild) is test mode.
	public init?(
		suiteID: String, environment: [String: String],
		debugBuild: Bool = MachmanTestMode.isDebugBuild
	) {
		guard MachmanTestMode.isActive(suiteID: suiteID, debugBuild: debugBuild) else {
			return nil
		}
		let token = String(suiteID.dropFirst(MachmanTestMode.suitePrefix.count))
		self.suiteID = suiteID
		self.token = token
		answersPath = Self.absolute(environment["MACHMAN_LAB_ANSWERS"])
		sshdHostKeyPath = Self.absolute(environment["MACHMAN_LAB_SSHD_HOSTKEY"])
		deviceOptIns = Set((environment["MACHMAN_LAB_DEVICES"] ?? "")
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
			.filter { !$0.isEmpty })
		// Only inside this run's sandbox: a stray variable can't bind a socket anywhere else.
		agentControlPath = Self.absolute(environment["MACHMAN_LAB_AGENT_CONTROL"])
			.flatMap { $0.contains(token) ? $0 : nil }
		var forwarded = ["MACHMAN_SUITE_ID": suiteID]
		for key in ["CFFIXED_USER_HOME", "HOME", "MACHMAN_DATA_DIR"] {
			if let value = environment[key], !value.isEmpty { forwarded[key] = value }
		}
		for (key, value) in environment where key.hasPrefix(Self.labPrefix) {
			forwarded[key] = value
		}
		forwardedVariables = forwarded
	}

	// This process's, under test mode; nil everywhere else.
	public static let current: LabEnvironment? = MachmanTestMode.isActive
		? LabEnvironment(
			suiteID: MachmanPaths.suiteIdentifier(),
			environment: ProcessInfo.processInfo.environment)
		: nil

	// A MACHMAN_LAB_* interval the lab shortens (seconds, positive and finite), else nil.
	public func seconds(_ name: String) -> Double? {
		guard name.hasPrefix(Self.labPrefix),
			let text = forwardedVariables[name]?.trimmingCharacters(in: .whitespaces),
			let value = Double(text), value.isFinite, value > 0 else { return nil }
		return value
	}

	private static func absolute(_ path: String?) -> String? {
		guard let path, path.hasPrefix("/") else { return nil }
		return path
	}
}
