//
//  HostQuiet.swift
//  MachmanTestSupport
//
//  The host-quiet check for a test process that hosts views (OffscreenHost): after a hosted
//  body, no window of the process is visible (AppKit's view, which sees a sheet or popover
//  the moment it is ordered) or on screen (the window server's, metadata only), the process
//  is not active, its activation policy is still .prohibited, and the keys of its standard
//  defaults domain did not change. That domain lives in the REAL home (cfprefsd ignores
//  CFFIXED_USER_HOME) and is what hosted views' @AppStorage reads and writes. The pasteboard
//  is deliberately not read: its contents are the user's.
//

import AppKit

@MainActor
public enum HostQuiet {
	// What the check reads, so a test can provoke every breach with a fake.
	public struct Probe {
		public var visibleWindowCount: @MainActor () -> Int
		public var onScreenWindowCount: @MainActor () -> Int
		public var isActive: @MainActor () -> Bool
		// nil while the process has no NSApp (no app: no Dock icon either).
		public var policy: @MainActor () -> NSApplication.ActivationPolicy?
		public var defaultsKeys: @MainActor () -> [String]

		public init(
			visibleWindowCount: @escaping @MainActor () -> Int,
			onScreenWindowCount: @escaping @MainActor () -> Int,
			isActive: @escaping @MainActor () -> Bool,
			policy: @escaping @MainActor () -> NSApplication.ActivationPolicy?,
			defaultsKeys: @escaping @MainActor () -> [String]
		) {
			self.visibleWindowCount = visibleWindowCount
			self.onScreenWindowCount = onScreenWindowCount
			self.isActive = isActive
			self.policy = policy
			self.defaultsKeys = defaultsKeys
		}
	}

	public struct Baseline: Sendable {
		public let defaultsKeys: [String]
	}

	// The standard defaults domain of the test process: an unbundled tool's is its name.
	public static var standardDomain: String {
		Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
	}

	public static let live = Probe(
		visibleWindowCount: {
			let app: NSApplication? = NSApp
			return app?.windows.filter(\.isVisible).count ?? 0
		},
		onScreenWindowCount: {
			let pid = ProcessInfo.processInfo.processIdentifier
			let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
				as? [[String: Any]] ?? []
			return onScreen.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.count
		},
		isActive: {
			let app: NSApplication? = NSApp
			return app?.isActive ?? false
		},
		policy: {
			let app: NSApplication? = NSApp
			return app?.activationPolicy()
		},
		defaultsKeys: {
			(UserDefaults.standard.persistentDomain(forName: standardDomain) ?? [:]).keys.sorted()
		})

	// probe nil: the live one.
	public static func baseline(_ probe: Probe? = nil) -> Baseline {
		Baseline(defaultsKeys: (probe ?? live).defaultsKeys())
	}

	// One sentence per breach since `baseline`; empty when the process stayed quiet.
	public static func breaches(since baseline: Baseline, probe: Probe? = nil) -> [String] {
		let probe = probe ?? live
		var found: [String] = []
		let visible = probe.visibleWindowCount()
		if visible > 0 {
			found.append("\(visible) window(s) of the test process are visible")
		}
		let onScreen = probe.onScreenWindowCount()
		if onScreen > 0 {
			found.append("\(onScreen) window(s) of the test process are on screen")
		}
		if probe.isActive() {
			found.append("the test process became the active app")
		}
		if let policy = probe.policy(), policy != .prohibited {
			found.append("the activation policy is \(policy.spoken), not .prohibited")
		}
		let keys = probe.defaultsKeys()
		if keys != baseline.defaultsKeys {
			let added = Set(keys).subtracting(baseline.defaultsKeys).sorted()
			let removed = Set(baseline.defaultsKeys).subtracting(keys).sorted()
			found.append("the '\(standardDomain)' defaults domain changed (added: "
				+ "\(added.joined(separator: ", ")); removed: \(removed.joined(separator: ", ")))")
		}
		return found
	}
}
