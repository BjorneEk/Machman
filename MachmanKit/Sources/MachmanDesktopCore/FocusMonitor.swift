//
//  FocusMonitor.swift
//  MachmanDesktopCore
//
//  One app-scoped watcher of whether the user is looking at Machman: it listens for the
//  notifications that can change the answer, asks a probe, and reports changes only. A burst
//  (one window resigning key as the next becomes key) is coalesced into one look after it
//  settles. No timer and no view: nothing retains it but its owner, and dropping it removes
//  its observers (P3 — the per-pane tracker it replaces leaked a 2 Hz timer per mount).
//

import Foundation

@MainActor
public final class FocusMonitor {
	private let probe: @MainActor () -> Bool
	private let onChange: @MainActor (Bool) -> Void
	private let observers: ObserverTokens
	private var last: Bool?
	private lazy var reports = NextTurnCoalescer { [weak self] in self?.report() }

	public init(
		center: NotificationCenter = .default, names: [Notification.Name],
		probe: @escaping @MainActor () -> Bool,
		onChange: @escaping @MainActor (Bool) -> Void
	) {
		self.probe = probe
		self.onChange = onChange
		observers = ObserverTokens(center: center)
		for name in names {
			observers.add(center.addObserver(forName: name, object: nil, queue: nil) {
				[weak self] _ in
				Task { @MainActor [weak self] in
					self?.reports.schedule()
				}
			})
		}
		report()
	}

	private func report() {
		let now = probe()
		guard now != last else { return }
		last = now
		onChange(now)
	}
}

// A watcher's observer registrations, removed when it goes (FocusMonitor, PasteboardWatch).
final class ObserverTokens: @unchecked Sendable {
	private let center: NotificationCenter
	private var tokens: [NSObjectProtocol] = []

	init(center: NotificationCenter) {
		self.center = center
	}

	func add(_ token: NSObjectProtocol) {
		tokens.append(token)
	}

	deinit {
		for token in tokens {
			center.removeObserver(token)
		}
	}
}
