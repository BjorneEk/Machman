//
//  CanvasTabItem.swift
//  MachmanDesktopUI
//
//  One tab of a canvas pane's strip (VMCanvasView).
//

import SwiftUI
import MachmanUI

// One strip tab (demo design): the icon swaps to a close button on hover, style follows the
// theme's tab style, and the custom drag gesture drives reorder/detach in the parent.
struct CanvasTabItem: View {
	let title: String
	let symbol: String
	let isTerminal: Bool
	let selected: Bool
	let dragging: Bool
	let detachedDrag: Bool
	let dragOffset: CGSize
	let canSplit: Bool
	let hasSiblings: Bool
	let tabStyle: MachmanTabStyle
	let metrics: MachmanMetrics
	let onSelect: () -> Void
	let onClose: () -> Void
	let onCloseOthers: () -> Void
	let onSplit: () -> Void
	let onTearOff: () -> Void
	let onDragChanged: (DragGesture.Value) -> Void
	let onDragEnded: () -> Void
	let reportFrame: (CGRect) -> Void
	// Draws the hover without a pointer (render scenes).
	var hoverPreview = false
	@State private var hovering = false

	private var hovered: Bool { hovering || hoverPreview }

	var body: some View {
		HStack(spacing: 5) {
			iconOrClose
			Text(title)
				.font(.system(size: metrics.tabFontSize,
					weight: selected ? .medium : .regular))
				.lineLimit(1)
		}
		.padding(.horizontal, metrics.padM)
		.frame(height: metrics.tabHeight)
		.background(tabBackground)
		.contentShape(Rectangle())
		.opacity(detachedDrag && dragging ? 0.15 : 1)
		.offset(dragOffset)
		.zIndex(dragging ? 5 : 0)
		.onHover { hovering = $0 }
		.onGeometryChange(for: CGRect.self) { proxy in
			proxy.frame(in: .named("machman-canvas"))
		} action: { frame in
			reportFrame(frame)
		}
		.onTapGesture { onSelect() }
		.gesture(
			DragGesture(minimumDistance: 5, coordinateSpace: .named("machman-canvas"))
				.onChanged { onDragChanged($0) }
				.onEnded { _ in onDragEnded() }
		)
		.contextMenu { menu }
		.help(title)
		// One element for VoiceOver (H39): a button that selects the tab, with closing as a
		// named action — the close button inside is the pointer's, not a second element.
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(title)
		.accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
		.accessibilityAction { onSelect() }
		.accessibilityAction(named: "Close Tab") { onClose() }
	}

	// Xcode behavior: the tab's icon swaps to a close button on hover — and the icon AREA
	// is the close target even before the hover render lands. The swap is cosmetic only:
	// with the button's existence gated on `hovering`, a fast move-and-click reached the
	// row before onHover re-rendered, fell through to onSelect, and a second click was
	// needed to actually close.
	private var iconOrClose: some View {
		Button(action: onClose) {
			Group {
				if hovered && !dragging {
					Image(systemName: MachmanSymbols.closeTab)
						.font(.system(size: 9, weight: .bold))
						.frame(width: 14, height: 14)
						.background(Circle().fill(Color.primary.opacity(0.12)))
				} else {
					Image(systemName: symbol)
						.font(.system(size: metrics.tabFontSize - 1))
						.foregroundStyle(selected && isTerminal
							? MachmanColors.selection : .secondary)
						.frame(width: 14, height: 14)
				}
			}
		}
		.buttonStyle(.plain)
		.help(closeHelp)
		.accessibilityLabel(closeHelp)   // image-only: VoiceOver reads the help (H32)
	}

	private var closeHelp: String { "Close tab" + (isTerminal ? " (disconnects)" : "") }

	// A tab that isn't selected rests unfilled and shows its hover plainly (C6): capsules at
	// the active-overlay strength (their selection is the accent, so the two never mix up),
	// rectangles a step below the selected tab's fill.
	@ViewBuilder
	private var tabBackground: some View {
		switch tabStyle {
		case .rectangular:
			Rectangle().fill(Color.primary.opacity(
				selected ? MachmanColors.activeOverlay
					: (hovered ? MachmanColors.quietHoverOverlay : 0)))
		case .capsule:
			if selected {
				Capsule().fill(MachmanColors.selection.opacity(0.16))
					.overlay(Capsule().strokeBorder(MachmanColors.selection.opacity(0.35)))
			} else {
				Capsule().fill(Color.primary.opacity(hovered ? MachmanColors.activeOverlay : 0))
			}
		}
	}

	@ViewBuilder
	private var menu: some View {
		Button("Close Tab") { onClose() }
		if hasSiblings {
			Button("Close Other Tabs") { onCloseOthers() }
		}
		Divider()
		if canSplit {
			Button {
				onSplit()
			} label: {
				Label("Split Right", systemImage: MachmanSymbols.splitRight)
			}
		}
		Button {
			onTearOff()
		} label: {
			Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
		}
	}
}
