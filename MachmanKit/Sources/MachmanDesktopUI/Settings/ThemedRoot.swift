//
//  ThemedRoot.swift
//  MachmanDesktopUI
//
//  Every window's root: the resolved MachmanTheme (from the Appearance settings) applied as
//  environment, color scheme and accent. The app wraps each of its scenes in it.
//

import SwiftUI
import MachmanUI

// The resolved theme as an observed object: recomputed on EVERY defaults write in the
// process (UserDefaults.didChangeNotification), published only when it actually changed.
// ObservableObject invalidation is unconditional — unlike App/scene-level @AppStorage,
// which does not reliably re-render scene content — so Settings edits apply instantly.
@MainActor
public final class ThemeStore: ObservableObject {
	@Published public private(set) var theme = MachmanTheme.fromDefaults()
	private var observer: NSObjectProtocol?

	public init() {
		observer = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
	}

	private func refresh() {
		let resolved = MachmanTheme.fromDefaults()
		if resolved != theme {
			theme = resolved
		}
	}
}

// Window-level theme application: environment for MachmanUI, the color scheme, and the
// accent (MachmanTheme.swift's machmanThemed).
public struct ThemedRoot<Content: View>: View {
	@ObservedObject var store: ThemeStore
	@ViewBuilder var content: Content

	public init(store: ThemeStore, @ViewBuilder content: () -> Content) {
		self.store = store
		self.content = content()
	}

	public var body: some View {
		content.machmanThemed(store.theme)
	}
}
