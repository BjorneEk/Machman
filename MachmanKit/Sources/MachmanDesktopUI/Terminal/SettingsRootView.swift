//
//  SettingsRootView.swift
//  MachmanDesktopUI
//
//  The app Settings window (⌘,). One tab today — the terminal-profile editor — in a TabView so
//  future settings groups drop in beside it.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

public struct SettingsRootView: View {
	@ObservedObject var profiles: TerminalProfileStore

	public init(profiles: TerminalProfileStore) {
		self.profiles = profiles
	}

	public var body: some View {
		TabView {
			AppearanceSettingsView()
				.tabItem { Label("Appearance", systemImage: MachmanSymbols.deviceGraphics) }
			TerminalSettingsView(store: profiles)
				.tabItem { Label("Terminal", systemImage: MachmanSymbols.tabTerminal) }
			BehaviourSettingsView()
				.tabItem { Label("Behaviour", systemImage: MachmanSymbols.tabConfig) }
		}
		.frame(width: 760, height: 560)
	}
}
