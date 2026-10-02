//
//  SettingsLock.swift
//  MachmanUI
//
//  E22 (decision 9): an inspector over a VM an older vmhost still runs locks its settings as a
//  whole (`settingsLocked`). What changes no setting stays live inside the lock
//  (`liveWhileSettingsLocked`): copy and reveal, guides and help, the actions the daemon
//  still allows on such a VM and the desktop's own per-VM choices. SwiftUI's enabled state
//  is an AND down the tree, so a child can't simply re-enable; the lock tells it apart from
//  any other reason a control is off.
//

import SwiftUI

private struct SettingsLockedKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	public var settingsLocked: Bool {
		get { self[SettingsLockedKey.self] }
		set { self[SettingsLockedKey.self] = newValue }
	}
}

extension View {
	public func settingsLocked(_ locked: Bool) -> some View {
		disabled(locked).environment(\.settingsLocked, locked)
	}

	// Inside a lock, enabled again, whatever disabled it on the way down: apply it outside
	// the control's own `.disabled`, which still counts.
	public func liveWhileSettingsLocked() -> some View {
		modifier(LiveWhileSettingsLocked())
	}
}

private struct LiveWhileSettingsLocked: ViewModifier {
	@Environment(\.settingsLocked) private var locked

	func body(content: Content) -> some View {
		content.transformEnvironment(\.isEnabled) { [locked] enabled in
			if locked { enabled = true }
		}
	}
}
