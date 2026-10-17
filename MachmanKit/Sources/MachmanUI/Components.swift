//
//  Components.swift
//  MachmanUI
//
//  The overhaul's standard building blocks (1.0.4 UI): status dot, safe badge, boot badge,
//  the Tux glyph, toggle icon button, path row, add tile, rename field. Content-layer
//  chrome — toolbar controls are native items and must not use MachmanButtonStyle.
//

import SwiftUI
import MachmanAPI

// MARK: - Status dot --------------------------------------------------------------------------

// VM state as a dot: green glow running, pulsing orange in transitions. Pair with
// text/tooltips — never color-only status.
public struct StatusDot: View {
	private let state: VMState
	private let size: CGFloat

	public init(state: VMState, size: CGFloat = 8) {
		self.state = state
		self.size = size
	}

	public var body: some View {
		Circle()
			.fill(color)
			.frame(width: size, height: size)
			.shadow(color: state == .running ? color.opacity(0.8) : .clear, radius: 3)
			.overlay {
				if state == .starting || state == .stopping {
					PulsingRing(color: color)
				}
			}
			.accessibilityLabel(state.displayLabel)
	}

	private var color: Color {
		switch state {
		case .running: return MachmanColors.stateRunning
		case .starting, .stopping: return MachmanColors.stateTransition
		case .error: return MachmanColors.stateError
		default: return MachmanColors.stateStopped.opacity(0.6)
		}
	}
}

struct PulsingRing: View {
	let color: Color
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var on = false

	// Reduce Motion gets a steady ring: up to four of these pulse at once during a start (H66).
	static func look(reduceMotion: Bool, on: Bool) -> (opacity: Double, animation: Animation?) {
		if reduceMotion { return (0.6, nil) }
		return (on ? 0.15 : 0.9, .easeInOut(duration: 0.7).repeatForever(autoreverses: true))
	}

	var body: some View {
		let look = Self.look(reduceMotion: reduceMotion, on: on)
		Circle()
			.stroke(color.opacity(0.5), lineWidth: 1.5)
			.scaleEffect(1.7)
			.opacity(look.opacity)
			.animation(look.animation, value: on)
			.onAppear { on = true }
	}
}

// MARK: - Safe badge --------------------------------------------------------------------------

public struct SafeBadge: View {
	private let compact: Bool

	public init(compact: Bool = false) {
		self.compact = compact
	}

	public var body: some View {
		Image(systemName: MachmanSymbols.safe)
			.font(.system(size: compact ? 9 : 12, weight: .semibold))
			.foregroundStyle(MachmanColors.safeMode)
			.help("Safe mode — changes are discarded on stop")
	}
}

// Composite safe-start glyph: the start symbol inside a shield outline.
public struct SafeStartGlyph: View {
	private let size: CGFloat

	public init(size: CGFloat = 14) {
		self.size = size
	}

	public var body: some View {
		ZStack {
			Image(systemName: MachmanSymbols.shield)
				.font(.system(size: size, weight: .medium))
			Image(systemName: MachmanSymbols.start)
				.font(.system(size: size * 0.45, weight: .bold))
				.offset(y: -size * 0.05)
		}
	}
}

// MARK: - Boot badge --------------------------------------------------------------------------

extension BootInfo.Mode {
	public var displayLabel: String {
		switch self {
		case .efi: return "EFI"
		case .linuxKernel: return "Kernel boot"
		case .macOS: return "macOS"
		case .unknown: return "Unknown"
		}
	}

	// The mode as a menu item (the Bootloader picker): Title Case, where labels and badges
	// take displayLabel's sentence case (W9).
	public var menuTitle: String {
		self == .linuxKernel ? "Kernel Boot" : displayLabel
	}
}

// Boot-kind icon + label (the VM indicator subtitle and picker rows). The label names the
// mode, so VoiceOver skips the glyph (EFI's read "Advanced", H51).
public struct BootBadge: View {
	private let mode: BootInfo.Mode
	private let size: CGFloat

	public init(mode: BootInfo.Mode, size: CGFloat = 10) {
		self.mode = mode
		self.size = size
	}

	public var body: some View {
		HStack(spacing: 3) {
			BootGlyph(mode: mode, size: size)
				.accessibilityHidden(true)
			Text(mode.displayLabel)
		}
		.font(.system(size: size))
		.foregroundStyle(.secondary)
	}
}

public struct BootGlyph: View {
	private let mode: BootInfo.Mode
	private let size: CGFloat

	public init(mode: BootInfo.Mode, size: CGFloat) {
		self.mode = mode
		self.size = size
	}

	public var body: some View {
		switch mode {
		case .macOS:
			Image(systemName: MachmanSymbols.bootMacTab).font(.system(size: size))
		case .linuxKernel:
			TuxIcon(size: size + 2)
		case .efi:
			Image(systemName: MachmanSymbols.bootEFI).font(.system(size: size))
		case .unknown:
			Image(systemName: MachmanSymbols.help).font(.system(size: size))
		}
	}
}

// Minimal stylized Tux (SF Symbols has no penguin). Reads at 10–48 pt.
public struct TuxIcon: View {
	private let size: CGFloat

	public init(size: CGFloat = 14) {
		self.size = size
	}

	public var body: some View {
		Canvas { ctx, sz in
			let w = sz.width, h = sz.height
			func ellipse(_ x: CGFloat, _ y: CGFloat, _ ww: CGFloat, _ hh: CGFloat) -> Path {
				Path(ellipseIn: CGRect(x: x * w, y: y * h, width: ww * w, height: hh * h))
			}
			let body = ellipse(0.16, 0.02, 0.68, 0.92)
			ctx.fill(body, with: .color(.black))
			ctx.stroke(body, with: .color(.white.opacity(0.35)), lineWidth: max(0.5, w * 0.03))
			ctx.fill(ellipse(0.28, 0.36, 0.44, 0.54), with: .color(.white))
			ctx.fill(ellipse(0.33, 0.13, 0.13, 0.13), with: .color(.white))
			ctx.fill(ellipse(0.54, 0.13, 0.13, 0.13), with: .color(.white))
			ctx.fill(ellipse(0.42, 0.24, 0.16, 0.09), with: .color(.orange))
			ctx.fill(ellipse(0.14, 0.88, 0.28, 0.11), with: .color(.orange))
			ctx.fill(ellipse(0.58, 0.88, 0.28, 0.11), with: .color(.orange))
		}
		.frame(width: size, height: size)
		.accessibilityLabel("Linux")
	}
}

// MARK: - Toggle icon button ------------------------------------------------------------------

// Icon button with a sticky on-state, for in-content chrome (toolbar toggles are native).
public struct ToggleIconButton: View {
	@Environment(\.isEnabled) private var enabled
	private let symbol: String
	private let tooltip: String
	private let isOn: Bool
	private let action: () -> Void

	public init(symbol: String, tooltip: String, isOn: Bool, action: @escaping () -> Void) {
		self.symbol = symbol
		self.tooltip = tooltip
		self.isOn = isOn
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.foregroundStyle(isOn ? MachmanColors.selection : Color.primary)
				.padding(.horizontal, 3)
				.background(
					RoundedRectangle(cornerRadius: 5, style: .continuous)
						.fill(MachmanColors.selection.opacity(isOn ? 0.14 : 0)))
		}
		.buttonStyle(MachmanButtonStyle(flat: true))
		.opacity(enabled ? 1 : MachmanColors.disabledOpacity)
		.help(tooltip)
		.accessibilityLabel(tooltip)
	}
}

// MARK: - Path row ----------------------------------------------------------------------------

// Standard inspector row for a filesystem path: middle-truncated monospaced text with
// copy + show-in-Finder buttons (icon-only, tooltips carry the labels).
public struct PathRow: View {
	private let label: String
	private let path: String
	private let onReveal: () -> Void

	public init(label: String, path: String, onReveal: @escaping () -> Void) {
		self.label = label
		self.path = path
		self.onReveal = onReveal
	}

	public var body: some View {
		LabeledContent(label) {
			HStack(spacing: 2) {
				Text(path)
					.font(.system(.caption, design: .monospaced))
					.truncationMode(.middle)
					.lineLimit(1)
					.help(path)
				CopyToClipboardButton(path, tooltip: "Copy path")
				IconButton(
					symbol: MachmanSymbols.showInFinder, tooltip: "Show in Finder",
					font: .callout, flat: true, action: onReveal)
				.liveWhileSettingsLocked()
			}
		}
	}
}

// MARK: - Number field ------------------------------------------------------------------------

extension View {
	// The one look of a number typed into an inspector (H46): bordered, the value trailing, a
	// fixed width. A value the user types has to look typed-in. Its label stays hidden: in a
	// grouped Form a bordered field keeps a line for its title above the box, which dropped
	// the value ~4 pt below the row's label.
	public func inspectorNumberField(width: CGFloat) -> some View {
		textFieldStyle(.roundedBorder)
			.labelsHidden()
			.multilineTextAlignment(.trailing)
			.frame(width: width)
	}
}

// MARK: - Add tile ----------------------------------------------------------------------------

// Icon-first tile for the "+" add popover. `badge` overlays a small plus for glyphs that
// have no `.badge.plus` variant of their own. VoiceOver reads its `name` ("New Disk…"): the
// caption alone ("New") is cut off from its section's header (H57). A `disabledReason` (a
// stop-first or capability gate) dims it and takes the tooltip from `tooltip`.
public struct AddTile: View {
	@Environment(\.isEnabled) private var enabled
	private let name: String
	private let symbol: String
	private let caption: String
	private let tooltip: String
	private let disabledReason: String?
	private let badge: Bool
	private let action: () -> Void
	@State private var hovering = false

	public init(
		_ name: String, symbol: String, caption: String, tooltip: String,
		disabledReason: String? = nil, badge: Bool = false, action: @escaping () -> Void
	) {
		self.name = name
		self.symbol = symbol
		self.caption = caption
		self.tooltip = tooltip
		self.disabledReason = disabledReason
		self.badge = badge
		self.action = action
	}

	private var offered: Bool { enabled && disabledReason == nil }

	public var body: some View {
		Button(action: action) {
			VStack(spacing: 3) {
				ZStack(alignment: .bottomTrailing) {
					Image(systemName: symbol)
						.font(.system(size: 16))
						.frame(width: 30, height: 22)
					if badge {
						Image(systemName: MachmanSymbols.add)
							.font(.system(size: 7, weight: .bold))
							.padding(2)
							.background(Circle().fill(.background))
							.offset(x: 3, y: 2)
					}
				}
				Text(caption)
					.font(.system(size: 9.5))
					.foregroundStyle(.secondary)
			}
			.frame(width: 64)
			.padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(Color.primary.opacity(hovering ? MachmanColors.hoverOverlay : 0)))
			.contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		}
		.buttonStyle(.plain)
		.disabled(disabledReason != nil)
		.opacity(offered ? 1 : MachmanColors.disabledOpacity)
		.onHover { hovering = offered && $0 }
		// On macOS the tooltip is the accessibility help VoiceOver reads after the name.
		.help(disabledReason ?? tooltip)
		.accessibilityLabel(name)
	}
}

// MARK: - Served draft ------------------------------------------------------------------------

extension View {
	// A field's draft of a value the daemon (or another store) serves — the inspectors' one
	// pattern (Q2). The draft starts as the served value, or `seed` (a render's unsent draft);
	// it follows the served value whenever that changes, unless the draft `holds` an edit not
	// sent yet or already `means` the new value; and an edit away from the served value clears
	// `refusal`, the reason the last commit was refused.
	public func servedDraft(
		_ draft: Binding<String>, of served: String, seed: String? = nil,
		refusal: Binding<String?>? = nil, holds: Bool = false,
		means: @escaping (String, String) -> Bool = { $0 == $1 }
	) -> some View {
		onAppear { draft.wrappedValue = seed ?? served }
			.onChange(of: served) {
				if !holds && !means(draft.wrappedValue, served) { draft.wrappedValue = served }
			}
			.onChange(of: draft.wrappedValue) {
				if draft.wrappedValue != served { refusal?.wrappedValue = nil }
			}
	}
}

// MARK: - Rename field ------------------------------------------------------------------------

// In-place rename editor: commits on Return, cancels on Esc or when focus moves elsewhere
// (a click outside it), auto-focuses. A draft with a `problem` shows the warning triangle
// with the reason as its help, and Return leaves it in the field.
public struct RenameField: View {
	private let initial: String
	private let problem: (String) -> String?
	private let commit: (String) -> Void
	private let cancel: () -> Void
	@State private var draft = ""
	@FocusState private var focused: Bool
	// Losing focus ends the rename only once the field had it: not in the frames before the
	// focus it asks for on appear lands.
	@State private var hadFocus = false

	public init(
		initial: String, problem: @escaping (String) -> String? = { _ in nil },
		commit: @escaping (String) -> Void, cancel: @escaping () -> Void
	) {
		self.initial = initial
		self.problem = problem
		self.commit = commit
		self.cancel = cancel
	}

	public var body: some View {
		HStack(spacing: 4) {
			field
			if let reason = problem(draft) {
				Image(systemName: MachmanSymbols.warning)
					.font(.system(size: 10))
					.foregroundStyle(MachmanColors.warning)
					.help(reason)
					.accessibilityLabel(reason)
			}
		}
	}

	private var field: some View {
		TextField("", text: $draft)
			.textFieldStyle(.plain)
			.focused($focused)
			.onSubmit { if problem(draft) == nil { commit(draft) } }
			.onExitCommand { cancel() }
			.onAppear {
				draft = initial
				focused = true
			}
			.onChange(of: focused) { _, now in
				if now {
					hadFocus = true
				} else if hadFocus {
					cancel()
				}
			}
	}
}
