//
//  MachmanTheme.swift
//  MachmanUI
//
//  The look-and-feel tokens (1.0.4 UI overhaul): one meaning = one color, sizes derived
//  from user-steppable density and font scales, and the per-window theme carried through
//  the environment. Same rule as MachmanSymbols: views reference these, never literals.
//

import SwiftUI

// MARK: - Colors ------------------------------------------------------------------------------

public enum MachmanColors {
	public static let stateRunning = Color.green
	public static let stateTransition = Color.orange       // starting / stopping
	public static let stateStopped = Color.secondary
	public static let stateError = Color.red
	public static let safeMode = Color.yellow              // kept from StatusIcon's shield
	public static let warning = Color.orange
	public static let accepted = Color.green               // a drop that will land
	public static let problem = Color.red                  // a refused drop, a copy that won't fit
	public static let destructiveConfirm = Color.red       // dialogs only; buttons stay mono
	// The accent tokens read Color.accentColor, which follows Settings ▸ Accent through
	// machmanThemed's .accentColor — except inside a sidebar List's rows, which reset it to
	// the system accent: code there reads the theme's accentColor instead (H20).
	public static let connected = Color.accentColor        // live serial dot
	public static let selection = Color.accentColor        // must track the user's accent
	public static let activeEntry = Color.accentColor      // active kernel / initramfs

	// Interaction overlay strengths (MachmanButtonStyle's long-standing values).
	public static let hoverOverlay = 0.06
	public static let quietHoverOverlay = 0.08             // a hovered row or flat control
	public static let activeOverlay = 0.12
	public static let pressedOverlay = 0.16
	public static let disabledOpacity = 0.4
	public static let inactiveEntryOpacity = 0.55          // non-active kernels, disabled rows
	public static let dimmedRowOpacity = 0.7               // group parents, config-less devices
}

// MARK: - Metrics -----------------------------------------------------------------------------

// Sizes derived from two independent user knobs: density scales ONLY padding/spacing/row
// heights; the font scale drives type and the inline icons that sit next to it. Floors keep
// the compact end usable. 1.0/1.0 reproduces today's literals (radius 5, strip ~32…).
public struct MachmanMetrics {
	public let scale: CGFloat
	public let fontScale: CGFloat
	// Explicit tab sizing (Settings knobs); nil derives from the scales as before.
	public let tabHeightOverride: CGFloat?
	public let tabFontOverride: CGFloat?

	public static let scaleRange: ClosedRange<Double> = 0.7...1.4
	public static let scaleStep = 0.05
	public static let fontScaleRange: ClosedRange<Double> = 0.8...1.3
	public static let fontScaleStep = 0.05
	public static let tabHeightRange: ClosedRange<Double> = 18...40
	public static let tabFontRange: ClosedRange<Double> = 9...16

	public init(
		scale: CGFloat = 1.0, fontScale: CGFloat = 1.0,
		tabHeightOverride: CGFloat? = nil, tabFontOverride: CGFloat? = nil
	) {
		self.scale = scale
		self.fontScale = fontScale
		self.tabHeightOverride = tabHeightOverride
		self.tabFontOverride = tabFontOverride
	}

	public var radiusS: CGFloat { 5 }
	public var radiusM: CGFloat { 8 }
	public var radiusL: CGFloat { 12 }
	public var treeRowHeight: CGFloat { max(16, (24 * scale).rounded()) }
	public var tabHeight: CGFloat {
		tabHeightOverride.map { max(16, $0.rounded()) } ?? max(18, (25 * scale).rounded())
	}
	// The strip tracks the tab height so the explicit knob moves both.
	public var tabStripHeight: CGFloat { tabHeight + max(6, (8 * scale).rounded()) }
	public var padS: CGFloat { max(2, (4 * scale).rounded()) }
	public var padM: CGFloat { max(4, (8 * scale).rounded()) }
	public var padL: CGFloat { max(8, (12 * scale).rounded()) }
	public var rowFontSize: CGFloat { max(10, (12.5 * fontScale).rounded()) }
	public var tabFontSize: CGFloat {
		tabFontOverride.map { max(8, $0.rounded()) } ?? max(10, (11.5 * fontScale).rounded())
	}
	public var iconSize: CGFloat { max(10, (13 * fontScale).rounded()) }
}

// MARK: - Theme knobs -------------------------------------------------------------------------

public enum MachmanTabStyle: String, CaseIterable, Identifiable, Codable {
	case rectangular, capsule
	public var id: String { rawValue }
	public var label: String { self == .rectangular ? "Rectangular" : "Capsule" }
}

public enum MachmanGlassLevel: String, CaseIterable, Identifiable, Codable {
	case standard, extra
	public var id: String { rawValue }
	public var label: String { self == .standard ? "Standard Chrome" : "Extra Glass" }

	// The Liquid Glass a MachmanGlassSurface draws on macOS 26: Extra glass is the clearer
	// variant; prominent surfaces react to the pointer; a tint washes either.
	@available(macOS 26.0, *)
	public func liquidGlass(prominent: Bool, tint: Color?) -> Glass {
		let base: Glass = self == .extra ? .clear : .regular
		let glass = prominent ? base.interactive() : base
		return tint.map { glass.tint($0) } ?? glass
	}
}

public enum MachmanScheme: String, CaseIterable, Identifiable, Codable {
	case system, light, dark
	public var id: String { rawValue }
	public var label: String { rawValue.capitalized }
	public var colorScheme: ColorScheme? {
		switch self {
		case .system: return nil
		case .light: return .light
		case .dark: return .dark
		}
	}
}

public enum MachmanAccent: String, CaseIterable, Identifiable, Codable {
	case system, blue, purple, orange, graphite
	public var id: String { rawValue }
	public var label: String { rawValue.capitalized }
	public var color: Color? {
		switch self {
		case .system: return nil
		case .blue: return .blue
		case .purple: return .purple
		case .orange: return .orange
		case .graphite: return Color(nsColor: .systemGray)
		}
	}
}

// The per-window resolved style. Settings feeds it; views read it from the environment.
public struct MachmanTheme: Equatable {
	public var tabStyle: MachmanTabStyle
	public var density: Double
	public var fontScale: Double
	public var glass: MachmanGlassLevel
	public var scheme: MachmanScheme
	public var accent: MachmanAccent
	// Explicit tab sizing in points; nil = derive from the scales.
	public var tabHeightOverride: Double?
	public var tabFontOverride: Double?

	public init(
		tabStyle: MachmanTabStyle = .rectangular, density: Double = 1.0,
		fontScale: Double = 1.0, glass: MachmanGlassLevel = .standard,
		scheme: MachmanScheme = .system, accent: MachmanAccent = .system,
		tabHeightOverride: Double? = nil, tabFontOverride: Double? = nil
	) {
		self.tabStyle = tabStyle
		self.density = density
		self.fontScale = fontScale
		self.glass = glass
		self.scheme = scheme
		self.accent = accent
		self.tabHeightOverride = tabHeightOverride
		self.tabFontOverride = tabFontOverride
	}

	public var metrics: MachmanMetrics {
		MachmanMetrics(
			scale: density, fontScale: fontScale,
			tabHeightOverride: tabHeightOverride.map { CGFloat($0) },
			tabFontOverride: tabFontOverride.map { CGFloat($0) })
	}
	public var accentColor: Color { accent.color ?? .accentColor }
}

private struct MachmanThemeKey: EnvironmentKey {
	static let defaultValue = MachmanTheme()
}

extension EnvironmentValues {
	public var machmanTheme: MachmanTheme {
		get { self[MachmanThemeKey.self] }
		set { self[MachmanThemeKey.self] = newValue }
	}
}

extension View {
	// A window's theme: the environment for MachmanUI, the color scheme and the accent.
	// Color.accentColor (MachmanColors' accent tokens) follows only .accentColor, never
	// .tint, so both are set — always, never behind an if, so changing the accent never
	// rebuilds the window's content; nil is the system accent. (.accentColor is soft-
	// deprecated without a replacement that reaches Color.accentColor.)
	public func machmanThemed(_ theme: MachmanTheme) -> some View {
		environment(\.machmanTheme, theme)
			.preferredColorScheme(theme.scheme.colorScheme)
			.tint(theme.accent.color)
			.accentColor(theme.accent.color)
	}
}
