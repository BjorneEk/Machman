//
//  FocusMonitorTests.swift
//  MachmanDesktopCoreTests
//
//  The app-scoped focus watcher behind preview polling (P3, T18): it reports the starting
//  state once, a burst of notifications as one change, and once dropped it is gone — no
//  timer or observer keeps it (or what it reports to) alive, the leak the per-pane tracker
//  had on every reconnect.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
private final class FocusProbe {
	var focused = false
	var reports: [Bool] = []
}

@MainActor
struct FocusMonitorTests {
	private static let name = Notification.Name("FocusMonitorTests.changed")

	private func monitor(_ probe: FocusProbe, _ center: NotificationCenter) -> FocusMonitor {
		FocusMonitor(
			center: center, names: [Self.name],
			probe: { probe.focused },
			onChange: { probe.reports.append($0) })
	}

	@Test func reportsTheInitialStateOnce() async {
		let probe = FocusProbe()
		let center = NotificationCenter()
		let watcher = monitor(probe, center)
		#expect(await settled { probe.reports })
		#expect(probe.reports == [false])
		withExtendedLifetime(watcher) {}
	}

	// Q41: the burst's report waited on a 5 s wall clock, which ran out at full load while
	// other tests held the main thread. The report is queued one main turn behind the posts
	// (no timer): it has landed once the work the posts set off has run out.
	@Test("Q41: a burst of focus notifications reports once")
	func coalescesABurst() async {
		let probe = FocusProbe()
		let center = NotificationCenter()
		let watcher = monitor(probe, center)
		probe.focused = true
		center.post(name: Self.name, object: nil)
		center.post(name: Self.name, object: nil)
		#expect(await settled { probe.reports })
		#expect(probe.reports == [false, true])
		// No change, no report.
		center.post(name: Self.name, object: nil)
		#expect(await settled { probe.reports })
		#expect(probe.reports == [false, true])
		withExtendedLifetime(watcher) {}
	}

	@Test func aReleasedMonitorIsGoneAndSilent() async {
		let probe = FocusProbe()
		let center = NotificationCenter()
		var watcher: FocusMonitor? = monitor(probe, center)
		weak var released = watcher
		#expect(released != nil)
		watcher = nil
		#expect(released == nil)
		probe.focused = true
		center.post(name: Self.name, object: nil)
		#expect(await settled { probe.reports })
		#expect(probe.reports == [false])
	}
}
