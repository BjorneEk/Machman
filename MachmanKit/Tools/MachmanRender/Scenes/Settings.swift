//
//  Settings.swift
//  MachmanRender
//
//  The Settings window (⌘,): its root TabView and each pane on its own, at the window's
//  fixed 760 × 600.
//

import SwiftUI
import MachmanUI
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

enum SettingsScenes {
	static func pane(
		_ name: String, _ summary: String,
		_ make: @escaping @MainActor (SceneContext) -> AnyView
	) -> RenderScene {
		RenderScene("settings.\(name)", summary, widths: [760], height: 600, make: make)
	}

	static let all: [RenderScene] = [
		pane("root", "SettingsRootView (tabs, Appearance first)") { ctx in
			AnyView(SettingsRootView(profiles: ctx.profiles))
		},
		pane("appearance", "AppearanceSettingsView") { _ in
			AnyView(AppearanceSettingsView())
		},
		// H20: the Glass control set to Extra glass (shown while the key is unset — no
		// defaults write). The glass itself renders in its Reduce Transparency form.
		pane("appearance.extra-glass", "AppearanceSettingsView, Glass set to Extra glass") { _ in
			AnyView(AppearanceSettingsView(glass: .extra))
		},
		pane("terminal", "TerminalSettingsView (profile editor, live preview)") { ctx in
			AnyView(TerminalSettingsView(store: ctx.profiles))
		},
		// H19: a profile naming a font this Mac doesn't have says so in the Family picker.
		pane("terminal.missing-font", "TerminalSettingsView, a profile whose font isn't installed")
		{ ctx in
			var profile = ctx.profiles.addProfile()
			profile.fontName = "Iosevka Term"
			ctx.profiles.update(profile)
			ctx.profiles.editingProfileID = profile.id
			return AnyView(TerminalSettingsView(store: ctx.profiles))
		},
		// P35: the scrollback field names its bound. Taller than the window, so the Behavior
		// section below the fold is in the picture.
		RenderScene(
			"settings.terminal.behavior", "TerminalSettingsView down to its Behavior section",
			widths: [760], height: 1100
		) { ctx in
			AnyView(TerminalSettingsView(store: ctx.profiles))
		},
		pane("behaviour", "BehaviourSettingsView") { _ in
			AnyView(BehaviourSettingsView())
		},
	]
}
