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

private struct PulsingRing: View {
	let color: Color
	@State private var on = false

	var body: some View {
		Circle()
			.stroke(color.opacity(0.5), lineWidth: 1.5)
			.scaleEffect(1.7)
			.opacity(on ? 0.15 : 0.9)
			.animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
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
}

// Boot-kind icon + label (the VM indicator subtitle and picker rows).
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
			}
		}
	}
}

// MARK: - Add tile ----------------------------------------------------------------------------

// Icon-first tile for the "+" add popover. `badge` overlays a small plus for glyphs that
// have no `.badge.plus` variant of their own. Dims when disabled (a capability-gated
// tile); the tooltip then carries the reason.
public struct AddTile: View {
	@Environment(\.isEnabled) private var enabled
	private let symbol: String
	private let caption: String
	private let tooltip: String
	private let badge: Bool
	private let action: () -> Void
	@State private var hovering = false

	public init(
		symbol: String, caption: String, tooltip: String, badge: Bool = false,
		action: @escaping () -> Void
	) {
		self.symbol = symbol
		self.caption = caption
		self.tooltip = tooltip
		self.badge = badge
		self.action = action
	}

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
		.opacity(enabled ? 1 : MachmanColors.disabledOpacity)
		.onHover { hovering = enabled && $0 }
		.help(tooltip)
	}
}

// MARK: - Rename field ------------------------------------------------------------------------

// In-place rename editor: commits on Return, cancels on Esc, auto-focuses.
public struct RenameField: View {
	private let initial: String
	private let commit: (String) -> Void
	private let cancel: () -> Void
	@State private var draft = ""
	@FocusState private var focused: Bool

	public init(
		initial: String, commit: @escaping (String) -> Void, cancel: @escaping () -> Void
	) {
		self.initial = initial
		self.commit = commit
		self.cancel = cancel
	}

	public var body: some View {
		TextField("", text: $draft)
			.textFieldStyle(.plain)
			.focused($focused)
			.onSubmit { commit(draft) }
			.onExitCommand { cancel() }
			.onAppear {
				draft = initial
				focused = true
			}
	}
}
