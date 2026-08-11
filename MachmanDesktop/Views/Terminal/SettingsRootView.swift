//
//  SettingsRootView.swift
//  MachmanDesktop
//
//  The app Settings window (⌘,). One tab today — the terminal-profile editor — in a TabView so
//  future settings groups drop in beside it.
//

import SwiftUI
import MachmanUI

struct SettingsRootView: View {
	@ObservedObject var profiles: TerminalProfileStore

	var body: some View {
		TabView {
			TerminalSettingsView(store: profiles)
				.tabItem { Label("Terminal", systemImage: MachmanSymbols.tabTerminal) }
		}
		.frame(width: 760, height: 560)
	}
}
