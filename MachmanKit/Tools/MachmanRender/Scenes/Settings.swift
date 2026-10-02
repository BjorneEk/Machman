//
//  Settings.swift
//  MachmanRender
//
//  The Settings window (⌘,): its root TabView and each pane on its own, at the window's
//  fixed 760 × 560.
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
		RenderScene("settings.\(name)", summary, widths: [760], height: 560, make: make)
	}

	static let all: [RenderScene] = [
		pane("root", "SettingsRootView (tabs, Appearance first)") { ctx in
			AnyView(SettingsRootView(profiles: ctx.profiles))
		},
		pane("appearance", "AppearanceSettingsView") { _ in
			AnyView(AppearanceSettingsView())
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
		pane("behaviour", "BehaviourSettingsView") { _ in
			AnyView(BehaviourSettingsView())
		},
	]
}
