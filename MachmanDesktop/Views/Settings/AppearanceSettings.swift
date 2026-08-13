//
//  AppearanceSettings.swift
//  MachmanDesktop
//
//  The Appearance and Behaviour settings tabs (1.0.4 UI) and the theme they feed: knobs
//  persist in UserDefaults and resolve into the MachmanTheme every window injects into the
//  environment, so scheme/accent/density/font-scale/tab-style apply live everywhere.
//

import SwiftUI
import MachmanUI

// One place for the persisted keys; MachmanTheme.fromDefaults() is what windows inject.
enum ThemeKeys {
	static let tabStyle = "MachmanThemeTabStyle"
	static let density = "MachmanThemeDensity"
	static let fontScale = "MachmanThemeFontScale"
	static let glass = "MachmanThemeGlass"
	static let scheme = "MachmanThemeScheme"
	static let accent = "MachmanThemeAccent"
}

extension MachmanTheme {
	static func fromDefaults(_ defaults: UserDefaults = .standard) -> MachmanTheme {
		let density = defaults.double(forKey: ThemeKeys.density)
		let fontScale = defaults.double(forKey: ThemeKeys.fontScale)
		return MachmanTheme(
			tabStyle: defaults.string(forKey: ThemeKeys.tabStyle)
				.flatMap(MachmanTabStyle.init) ?? .rectangular,
			density: density > 0 ? density : 1.0,
			fontScale: fontScale > 0 ? fontScale : 1.0,
			glass: defaults.string(forKey: ThemeKeys.glass)
				.flatMap(MachmanGlassLevel.init) ?? .standard,
			scheme: defaults.string(forKey: ThemeKeys.scheme)
				.flatMap(MachmanScheme.init) ?? .system,
			accent: defaults.string(forKey: ThemeKeys.accent)
				.flatMap(MachmanAccent.init) ?? .system)
	}
}

struct AppearanceSettingsView: View {
	@AppStorage(ThemeKeys.scheme) private var schemeRaw = MachmanScheme.system.rawValue
	@AppStorage(ThemeKeys.accent) private var accentRaw = MachmanAccent.system.rawValue
	@AppStorage(ThemeKeys.tabStyle) private var tabStyleRaw
		= MachmanTabStyle.rectangular.rawValue
	@AppStorage(ThemeKeys.density) private var density = 1.0
	@AppStorage(ThemeKeys.fontScale) private var fontScale = 1.0

	var body: some View {
		Form {
			Section("Look") {
				Picker("Appearance", selection: $schemeRaw) {
					ForEach(MachmanScheme.allCases) { scheme in
						Text(scheme.label).tag(scheme.rawValue)
					}
				}
				Picker("Accent", selection: $accentRaw) {
					ForEach(MachmanAccent.allCases) { accent in
						Text(accent.label).tag(accent.rawValue)
					}
				}
				Picker("Tab style", selection: $tabStyleRaw) {
					ForEach(MachmanTabStyle.allCases) { style in
						Text(style.label).tag(style.rawValue)
					}
				}
			}
			Section("Density") {
				LabeledContent("Spacing") {
					Slider(
						value: $density, in: MachmanMetrics.scaleRange,
						step: MachmanMetrics.scaleStep)
					Text(density.formatted(.percent.precision(.fractionLength(0))))
						.monospacedDigit()
						.frame(width: 44, alignment: .trailing)
				}
				.help("Scales padding, spacing, and row heights — not type")
				LabeledContent("Font size") {
					Slider(
						value: $fontScale, in: MachmanMetrics.fontScaleRange,
						step: MachmanMetrics.fontScaleStep)
					Text(fontScale.formatted(.percent.precision(.fractionLength(0))))
						.monospacedDigit()
						.frame(width: 44, alignment: .trailing)
				}
				.help("Scales type and the inline icons beside it")
				Button("Reset to Defaults") {
					density = 1.0
					fontScale = 1.0
					schemeRaw = MachmanScheme.system.rawValue
					accentRaw = MachmanAccent.system.rawValue
					tabStyleRaw = MachmanTabStyle.rectangular.rawValue
				}
			}
		}
		.formStyle(.grouped)
	}
}

struct BehaviourSettingsView: View {
	@AppStorage(VMListViewModel.toastSecondsKey) private var toastSeconds
		= VMListViewModel.defaultToastSeconds

	var body: some View {
		Form {
			Section("Notifications") {
				LabeledContent("Toast lifetime") {
					Slider(value: $toastSeconds, in: 2...15, step: 1)
					Text("\(Int(toastSeconds)) s")
						.monospacedDigit()
						.frame(width: 34, alignment: .trailing)
				}
				.help("How long warnings and confirmations stay in the corner")
			}
		}
		.formStyle(.grouped)
	}
}
