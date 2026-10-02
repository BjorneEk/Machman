//
//  AppearanceSettings.swift
//  MachmanDesktopUI
//
//  The Appearance and Behavior settings tabs (1.0.4 UI) and the theme they feed: knobs
//  persist in UserDefaults and resolve into the MachmanTheme every window injects into the
//  environment, so scheme/accent/glass/density/font-scale/tab-style apply live everywhere.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

// One place for the persisted keys; MachmanTheme.fromDefaults() is what windows inject.
enum ThemeKeys {
	static let tabStyle = "MachmanThemeTabStyle"
	static let density = "MachmanThemeDensity"
	static let fontScale = "MachmanThemeFontScale"
	static let glass = "MachmanThemeGlass"
	static let scheme = "MachmanThemeScheme"
	static let accent = "MachmanThemeAccent"
	// Explicit tab sizing in points; 0/absent = auto (derived from the scales).
	static let tabHeight = "MachmanThemeTabHeight"
	static let tabFontSize = "MachmanThemeTabFontSize"
}

extension MachmanTheme {
	static func fromDefaults(_ defaults: UserDefaults = .standard) -> MachmanTheme {
		let density = defaults.double(forKey: ThemeKeys.density)
		let fontScale = defaults.double(forKey: ThemeKeys.fontScale)
		let tabHeight = defaults.double(forKey: ThemeKeys.tabHeight)
		let tabFont = defaults.double(forKey: ThemeKeys.tabFontSize)
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
				.flatMap(MachmanAccent.init) ?? .system,
			tabHeightOverride: tabHeight > 0 ? tabHeight : nil,
			tabFontOverride: tabFont > 0 ? tabFont : nil)
	}
}

struct AppearanceSettingsView: View {
	@AppStorage(ThemeKeys.scheme) private var schemeRaw = MachmanScheme.system.rawValue
	@AppStorage(ThemeKeys.accent) private var accentRaw = MachmanAccent.system.rawValue
	@AppStorage(ThemeKeys.tabStyle) private var tabStyleRaw
		= MachmanTabStyle.rectangular.rawValue
	@AppStorage(ThemeKeys.density) private var density = 1.0
	@AppStorage(ThemeKeys.fontScale) private var fontScale = 1.0
	@AppStorage(ThemeKeys.tabHeight) private var tabHeight = 0.0
	@AppStorage(ThemeKeys.tabFontSize) private var tabFontSize = 0.0
	@AppStorage private var glassRaw: String

	// `glass` is what shows while the key is unset (render scenes; the app passes nothing).
	init(glass: MachmanGlassLevel = .standard) {
		_glassRaw = AppStorage(wrappedValue: glass.rawValue, ThemeKeys.glass)
	}

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
				Picker("Glass", selection: $glassRaw) {
					ForEach(MachmanGlassLevel.allCases) { level in
						Text(level.label).tag(level.rawValue)
					}
				}
				.help("Extra glass makes Machman’s own glass surfaces clearer")
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
					glassRaw = MachmanGlassLevel.standard.rawValue
					tabHeight = 0
					tabFontSize = 0
				}
			}
			Section("Tab bar") {
				LabeledContent("Tab height") {
					Slider(
						value: explicitBinding($tabHeight, auto: 25),
						in: MachmanMetrics.tabHeightRange, step: 1)
					Text(tabHeight > 0 ? "\(Int(tabHeight)) pt" : "Auto")
						.monospacedDigit()
						.frame(width: 44, alignment: .trailing)
				}
				LabeledContent("Tab font size") {
					Slider(
						value: explicitBinding($tabFontSize, auto: 11.5),
						in: MachmanMetrics.tabFontRange, step: 0.5)
					Text(tabFontSize > 0
						? tabFontSize.formatted(.number.precision(.fractionLength(0...1)))
							+ " pt"
						: "Auto")
						.monospacedDigit()
						.frame(width: 44, alignment: .trailing)
				}
				Button("Follow Density & Font Size") {
					tabHeight = 0
					tabFontSize = 0
				}
				.help("Clears the explicit sizes; tabs derive from the sliders above again")
			}
		}
		.formStyle(.grouped)
	}

	// 0 means auto: the slider shows the derived default until the user drags it, which
	// makes the value explicit.
	private func explicitBinding(_ storage: Binding<Double>, auto: Double) -> Binding<Double> {
		Binding(
			get: { storage.wrappedValue > 0 ? storage.wrappedValue : auto },
			set: { storage.wrappedValue = $0 })
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
