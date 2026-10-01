//
//  VMCanvasView.swift
//  MachmanDesktopUI
//
//  The editor-style canvas for one VM (1.0.4 UI, demo-parity): up to three panes with
//  Xcode-like tab strips, a custom drag system — live in-strip reorder, pull down (or off
//  the strip) to detach into a ghost with measured drop zones (move between panes, split a
//  new edge pane), release outside the canvas to tear the tab off into its own window —
//  and draggable pane dividers. Layout is the CanvasState value persisted per VM by
//  CanvasStateStore; live terminals stay in TerminalSessions and reparent wherever the tab
//  goes.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

private let dividerWidth: CGFloat = 9

// The in-flight tab drag: translation drives in-strip reorder until the tab detaches
// (pulled down or off its strip), after which the ghost + drop zones take over.
private struct TabDragState {
	var tab: VMPaneTab
	var paneID: UUID
	var location: CGPoint
	var translation: CGSize
	var detached = false
	// Widths of siblings crossed during live reorder, so the tab stays under the cursor.
	var baselineShift: CGFloat = 0
}

private enum CanvasDropZone: Equatable {
	case pane(UUID)
	case newLeading
	case newTrailing
}

struct VMCanvasView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	@ObservedObject var profiles: TerminalProfileStore
	let vm: VMInfo

	@State private var tabDrag: TabDragState?
	// Measured geometry lives in PLAIN REFERENCE storage: writing frames back into
	// @State re-enters layout, which oscillates during live resize ("Geometry action is
	// cycling between duplicate values"). The drag system reads these imperatively from
	// gesture callbacks, and tabDrag's own @State updates drive every render that draws
	// from them (drop zones, reorder) — so the reports never need to invalidate anything.
	private final class FrameStore {
		var canvasSize: CGSize = .zero
		var panes: [UUID: CGRect] = [:]
		var strips: [UUID: CGRect] = [:]
		var tabs: [VMPaneTab: CGRect] = [:]
	}
	@State private var frames = FrameStore()
	// Divider drags apply fractions absolutely from the drag-start snapshot.
	@State private var dragBaseFractions: [Double]?
	@Environment(\.machmanTheme) private var theme
	@Environment(\.openWindow) private var openWindow

	private var canvas: CanvasState { canvases.canvas(for: vm.name) }

	var body: some View {
		GeometryReader { geo in
			let c = canvas
			HStack(spacing: 0) {
				ForEach(Array(c.panes.enumerated()), id: \.element.id) { index, pane in
					paneView(pane, canvas: c)
						.frame(width: paneWidth(index, canvas: c, total: geo.size.width))
					if index < c.panes.count - 1 {
						paneDivider(index)
					}
				}
			}
			.overlay(alignment: .topLeading) {
				if tabDrag?.detached == true {
					dropZonesOverlay()
						.frame(width: geo.size.width, height: geo.size.height,
							alignment: .topLeading)
				}
			}
			// Reports into the reference store — never @State (see FrameStore).
			.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
				frames.canvasSize = size
			}
		}
		.coordinateSpace(name: "machman-canvas")
		.background(Color(nsColor: .underPageBackgroundColor))
		.onAppear { ensureConfigTab() }
		.onChange(of: vm.name) {
			tabDrag = nil
			frames.panes = [:]
			frames.strips = [:]
			frames.tabs = [:]
			ensureConfigTab()
		}
	}

	// A canvas with nothing open shows the config tab (fresh VM; reopenable if closed) —
	// unless a torn-off window already holds it (single mount). Deferred: this runs from
	// onAppear, and publishing store changes mid-view-update is undefined behavior.
	private func ensureConfigTab() {
		let name = vm.name
		DispatchQueue.main.async { [weak canvases] in
			guard let canvases,
				canvases.canvas(for: name).allOpenTabs.isEmpty,
				!TornTabRegistry.shared.isOpen(vm: name, tab: .config) else { return }
			var canvas = canvases.canvas(for: name)
			canvas.open(.config)
			canvases.setCanvas(canvas, for: name)
		}
	}

	private func mutate(_ change: (inout CanvasState) -> Void) {
		var c = canvases.canvas(for: vm.name)
		change(&c)
		canvases.setCanvas(c, for: vm.name)
	}

	// MARK: - Layout

	private func paneWidth(_ index: Int, canvas: CanvasState, total: CGFloat) -> CGFloat {
		let available = total - dividerWidth * CGFloat(canvas.panes.count - 1)
		let fraction = canvas.fractions.indices.contains(index)
			? canvas.fractions[index] : 1.0 / Double(canvas.panes.count)
		return max(120, available * CGFloat(fraction))
	}

	private func paneDivider(_ index: Int) -> some View {
		ZStack {
			Color.clear
			Rectangle()
				.fill(Color(nsColor: .separatorColor))
				.frame(width: 1)
		}
		.frame(width: dividerWidth)
		.contentShape(Rectangle())
		.onHover { inside in
			if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
		}
		.gesture(
			DragGesture(coordinateSpace: .named("machman-canvas"))
				.onChanged { value in
					let base = dragBaseFractions ?? canvas.fractions
					if dragBaseFractions == nil { dragBaseFractions = base }
					guard base.indices.contains(index) else { return }
					let available = max(200, frames.canvasSize.width
						- dividerWidth * CGFloat(canvas.panes.count - 1))
					let delta = Double(value.translation.width / available)
					mutate { $0.setFraction(base[index] + delta, at: index) }
				}
				.onEnded { _ in dragBaseFractions = nil }
		)
	}

	// MARK: - Pane

	private func paneView(_ pane: CanvasPane, canvas: CanvasState) -> some View {
		VStack(spacing: 0) {
			paneStrip(pane, canvas: canvas)
			if canvas.panes.count > 1 {
				// The active-pane hint: sidebar clicks and ⌘-cycling land here.
				Rectangle()
					.fill(pane.id == canvas.activePaneID
						? MachmanColors.selection.opacity(0.55) : Color.clear)
					.frame(height: 2)
			}
			paneContent(pane)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.onGeometryChange(for: CGRect.self) { proxy in
			proxy.frame(in: .named("machman-canvas"))
		} action: { frame in
			if frames.panes[pane.id] != frame { frames.panes[pane.id] = frame }
		}
	}

	private func paneStrip(_ pane: CanvasPane, canvas: CanvasState) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: theme.tabStyle == .capsule ? 6 : 0) {
				ForEach(pane.tabs, id: \.self) { tab in
					CanvasTabItem(
						title: tabTitle(tab),
						symbol: tabSymbol(tab),
						isTerminal: isTerminal(tab),
						selected: pane.active == tab,
						dragging: tabDrag?.tab == tab,
						detachedDrag: tabDrag?.detached == true,
						dragOffset: dragOffset(for: tab),
						canSplit: canvas.panes.count < CanvasState.maxPanes,
						hasSiblings: pane.tabs.count > 1,
						tabStyle: theme.tabStyle,
						metrics: theme.metrics,
						onSelect: { mutate { $0.activate(tab) } },
						onClose: { close(tab) },
						onCloseOthers: { closeOthers(than: tab, in: pane) },
						onSplit: { mutate { $0.split(tab, trailing: true) } },
						onTearOff: { tearOff(tab) },
						onDragChanged: { updateTabDrag(tab: tab, pane: pane.id, value: $0) },
						onDragEnded: { completeTabDrag() },
						reportFrame: { if frames.tabs[tab] != $0 { frames.tabs[tab] = $0 } })
					if theme.tabStyle == .rectangular && tab != pane.tabs.last {
						Divider().frame(height: theme.metrics.tabHeight * 0.6)
					}
				}
			}
			.padding(.horizontal, theme.tabStyle == .capsule ? 8 : 0)
			.padding(.vertical, theme.tabStyle == .capsule ? 4 : 0)
		}
		.frame(height: theme.metrics.tabStripHeight)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onGeometryChange(for: CGRect.self) { proxy in
			proxy.frame(in: .named("machman-canvas"))
		} action: { frame in
			if frames.strips[pane.id] != frame { frames.strips[pane.id] = frame }
		}
		.background {
			if theme.tabStyle == .rectangular {
				Rectangle().fill(.thinMaterial)
			}
		}
		.overlay(alignment: .bottom) {
			if theme.tabStyle == .rectangular {
				Divider()
			}
		}
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture().onEnded {
			mutate { $0.activatePane(pane.id) }
		})
	}

	private func dragOffset(for tab: VMPaneTab) -> CGSize {
		guard let drag = tabDrag, drag.tab == tab, !drag.detached else { return .zero }
		return CGSize(
			width: drag.translation.width - drag.baselineShift,
			height: max(-4, min(4, drag.translation.height * 0.2)))
	}

	// MARK: - Tab actions

	private func close(_ tab: VMPaneTab) {
		sessions.drop(tab, vm: vm.name)
		mutate { $0.close(tab) }
		viewModel.tabClosed(tab, vm: vm.name)
	}

	private func closeOthers(than tab: VMPaneTab, in pane: CanvasPane) {
		for other in pane.tabs where other != tab {
			close(other)
		}
	}

	// Tear a tab off into its own window: the canvas tab closes but the controller stays —
	// the new window adopts the same terminal (one mount at a time). The window is opened
	// on the NEXT runloop turn so SwiftUI finishes removing this mount first; opening it
	// inline makes the window's container adopt the terminal while the canvas's is still
	// alive, and the outgoing mount's last update takes it back.
	private func tearOff(_ tab: VMPaneTab) {
		mutate { $0.close(tab) }
		viewModel.tabClosed(tab, vm: vm.name)   // next row click focuses the window
		let payload = TornTab(vm: vm.name, tab: tab)
		DispatchQueue.main.async { openWindow(id: "torn-tab", value: payload) }
	}

	// MARK: - Drag logic (demo parity)

	private func updateTabDrag(tab: VMPaneTab, pane: UUID, value: DragGesture.Value) {
		var drag = tabDrag ?? TabDragState(
			tab: tab, paneID: pane, location: value.location,
			translation: value.translation)
		drag.location = value.location
		drag.translation = value.translation
		// Ghost mode when pulled down OR whenever the cursor leaves the source strip — the
		// strips are clipping ScrollViews, so only the top-level ghost can cross panes.
		let inSourceStrip = frames.strips[drag.paneID]?
			.insetBy(dx: -8, dy: -8).contains(value.location) ?? true
		let shouldDetach = abs(value.translation.height) > 42 || !inSourceStrip
		if shouldDetach != drag.detached {
			withAnimation(.snappy(duration: 0.18)) { drag.detached = shouldDetach }
		}
		if !drag.detached {
			reorderIfNeeded(&drag)
		}
		tabDrag = drag
	}

	// Live reorder: when the cursor passes a sibling tab's midpoint, move the tab and add
	// the sibling's width to the baseline so the dragged tab stays under the cursor.
	private func reorderIfNeeded(_ drag: inout TabDragState) {
		let c = canvas
		guard let holder = c.pane(holding: drag.tab),
			let pane = c.panes.first(where: { $0.id == holder }),
			let ti = pane.tabs.firstIndex(of: drag.tab) else { return }
		let x = drag.location.x
		var target = ti
		if ti + 1 < pane.tabs.count,
			let next = frames.tabs[pane.tabs[ti + 1]], x > next.midX + 2 {
			target = ti + 1
			drag.baselineShift += next.width
		} else if ti > 0,
			let prev = frames.tabs[pane.tabs[ti - 1]], x < prev.midX - 2 {
			target = ti - 1
			drag.baselineShift -= prev.width
		}
		guard target != ti else { return }
		let tab = drag.tab
		withAnimation(.snappy(duration: 0.18)) {
			mutate { $0.reorder(tab, to: target) }
		}
	}

	private func completeTabDrag() {
		guard let drag = tabDrag else { return }
		defer {
			withAnimation(.snappy(duration: 0.2)) { tabDrag = nil }
		}
		guard drag.detached else { return }
		let loc = drag.location
		// Released outside the canvas (with margin) → tear off into its own window.
		let canvasRect = CGRect(origin: .zero, size: frames.canvasSize).insetBy(dx: -40, dy: -40)
		if !canvasRect.contains(loc) {
			tearOff(drag.tab)
			return
		}
		// Released over a strip → insert at that position.
		if let (paneID, index) = stripInsertion(at: loc, excluding: drag.tab) {
			mutate { $0.move(drag.tab, toPane: paneID, at: index) }
			return
		}
		switch zone(at: loc) {
		case .pane(let id):
			if id != drag.paneID {
				mutate { c in
					let count = c.panes.first { $0.id == id }?.tabs
						.filter { $0 != drag.tab }.count ?? 0
					c.move(drag.tab, toPane: id, at: count)
				}
			}
		case .newLeading:
			mutate { $0.split(drag.tab, trailing: false) }
		case .newTrailing:
			mutate { $0.split(drag.tab, trailing: true) }
		case nil:
			break
		}
	}

	// Which strip is under the cursor, and the insertion index among its tabs (computed
	// EXCLUDING the dragged tab, so it stays valid after removal).
	private func stripInsertion(
		at loc: CGPoint, excluding dragged: VMPaneTab
	) -> (UUID, Int)? {
		for pane in canvas.panes {
			guard let strip = frames.strips[pane.id],
				strip.insetBy(dx: 0, dy: -6).contains(loc) else { continue }
			let index = pane.tabs
				.filter { $0 != dragged }
				.filter { tab in
					guard let frame = frames.tabs[tab] else { return false }
					return frame.midX < loc.x
				}
				.count
			return (pane.id, index)
		}
		return nil
	}

	// Zone rects in canvas space, from MEASURED pane frames (immune to sidebar/inspector
	// state); edge split-zones first, they win overlaps.
	private func dropZones() -> [(CanvasDropZone, CGRect)] {
		let size = frames.canvasSize
		guard size.width > 0 else { return [] }
		let c = canvas
		var zones: [(CanvasDropZone, CGRect)] = []
		let edge = max(56, size.width * 0.11)
		if c.panes.count < CanvasState.maxPanes {
			zones.append((.newLeading,
				CGRect(x: 4, y: 4, width: edge, height: size.height - 8)))
			zones.append((.newTrailing,
				CGRect(x: size.width - edge - 4, y: 4, width: edge, height: size.height - 8)))
		}
		for (i, pane) in c.panes.enumerated() {
			guard let measured = frames.panes[pane.id] else { continue }
			let edgePane = i == 0 || i == c.panes.count - 1
			let inset: CGFloat = c.panes.count < CanvasState.maxPanes && edgePane
				? (edge + 10) * 0.5 : 12
			zones.append((.pane(pane.id), measured.insetBy(dx: inset, dy: 24)))
		}
		return zones
	}

	private func zone(at location: CGPoint) -> CanvasDropZone? {
		dropZones().first { $0.1.contains(location) }?.0
	}

	// MARK: - Drop-zone overlay + ghost

	private func dropZonesOverlay() -> some View {
		let zones = dropZones()
		let location = tabDrag?.location ?? .zero
		let hovered = zone(at: location)
		// Full-size top-leading root: children are positioned by absolute canvas rects, so
		// the overlay must never be center-aligned by its container.
		return ZStack(alignment: .topLeading) {
			Color.clear
			ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
				let isHovered = hovered == zone.0
				RoundedRectangle(cornerRadius: theme.metrics.radiusM, style: .continuous)
					.fill(MachmanColors.selection.opacity(isHovered ? 0.16 : 0.05))
					.overlay {
						RoundedRectangle(
							cornerRadius: theme.metrics.radiusM, style: .continuous)
							.strokeBorder(
								MachmanColors.selection.opacity(isHovered ? 0.7 : 0.25),
								style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
					}
					.overlay {
						zoneLabel(zone.0)
							.opacity(isHovered ? 1 : 0.55)
					}
					.frame(width: zone.1.width, height: zone.1.height)
					.offset(x: zone.1.minX, y: zone.1.minY)
					.animation(.easeOut(duration: 0.12), value: isHovered)
			}
			ghost(at: location)
		}
		.allowsHitTesting(false)
	}

	@ViewBuilder
	private func zoneLabel(_ zone: CanvasDropZone) -> some View {
		switch zone {
		case .pane:
			Label("Move Here", systemImage: MachmanSymbols.moveHere)
				.font(.system(size: 11, weight: .medium))
		case .newTrailing, .newLeading:
			Label("Split", systemImage: MachmanSymbols.splitRight)
				.font(.system(size: 11, weight: .medium))
		}
	}

	@ViewBuilder
	private func ghost(at location: CGPoint) -> some View {
		if let drag = tabDrag {
			HStack(spacing: 5) {
				Image(systemName: tabSymbol(drag.tab)).font(.system(size: 10))
				Text(tabTitle(drag.tab)).font(.system(size: 11.5))
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 5)
			.machmanGlassCapsule(prominent: true)
			.offset(x: location.x + 10, y: location.y + 8)
		}
	}

	// MARK: - Content

	@ViewBuilder
	private func paneContent(_ pane: CanvasPane) -> some View {
		switch pane.active {
		case nil:
			emptyCanvas
		case .config:
			VMPreviewTabView(vm: vm, viewModel: viewModel)
		case .terminal(let ref):
			TerminalTabContent(
				sessions: sessions, profiles: profiles, vm: vm, ref: ref,
				stillWanted: { [weak canvases] in
					canvases?.canvas(for: vm.name).allOpenTabs
						.contains(.terminal(ref)) == true
				})
		case .ssh(let ref):
			SSHTabContent(
				sessions: sessions, viewModel: viewModel, profiles: profiles,
				vm: vm, ref: ref,
				stillWanted: { [weak canvases] in
					canvases?.canvas(for: vm.name).allOpenTabs
						.contains(.ssh(ref)) == true
				})
		}
	}

	private var emptyCanvas: some View {
		VStack(spacing: 10) {
			Image(systemName: MachmanSymbols.vm)
				.font(.system(size: 36, weight: .light))
				.foregroundStyle(.tertiary)
			Text("No open tabs")
				.font(.title3)
				.foregroundStyle(.secondary)
			Text("Click the VM, a console, or a UART in the sidebar to open it here.")
				.font(.callout)
				.foregroundStyle(.tertiary)
			Button {
				mutate { $0.open(.config) }
			} label: {
				Label("Open \(vm.name)", systemImage: MachmanSymbols.tabConfig)
			}
			.buttonStyle(MachmanButtonStyle())
			.padding(.top, 4)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - Tab metadata

	private func isTerminal(_ tab: VMPaneTab) -> Bool {
		switch tab {
		case .terminal, .ssh: return true
		case .config: return false
		}
	}

	private func tabSymbol(_ tab: VMPaneTab) -> String {
		switch tab {
		case .config:
			return MachmanSymbols.tabConfig
		case .terminal(let ref):
			return ref.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart
		case .ssh:
			return MachmanSymbols.deviceSSHSetup
		}
	}

	private func tabTitle(_ tab: VMPaneTab) -> String {
		switch tab {
		case .config:
			return vm.name
		case .terminal(let ref):
			let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
			return ports?.first(where: { $0.index == ref.index })?
				.displayName(mode: vm.boot.mode)
				?? ref.displayName(mode: vm.boot.mode)
		case .ssh(let ref):
			return sessions.sshSessionName(vm: vm.name, ref: ref)
		}
	}
}

// MARK: - Tab item ----------------------------------------------------------------------------

// One strip tab (demo design): the icon swaps to a close button on hover, style follows the
// theme's tab style, and the custom drag gesture drives reorder/detach in the parent.
private struct CanvasTabItem: View {
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
	@State private var hovering = false

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
	}

	// Xcode behavior: the tab's icon swaps to a close button on hover — and the icon AREA
	// is the close target even before the hover render lands. The swap is cosmetic only:
	// with the button's existence gated on `hovering`, a fast move-and-click reached the
	// row before onHover re-rendered, fell through to onSelect, and a second click was
	// needed to actually close.
	private var iconOrClose: some View {
		Button(action: onClose) {
			Group {
				if hovering && !dragging {
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
		.help("Close tab" + (isTerminal ? " (disconnects)" : ""))
	}

	@ViewBuilder
	private var tabBackground: some View {
		switch tabStyle {
		case .rectangular:
			Rectangle().fill(Color.primary.opacity(
				selected ? MachmanColors.activeOverlay
					: (hovering ? MachmanColors.hoverOverlay : 0)))
		case .capsule:
			if selected {
				Capsule().fill(MachmanColors.selection.opacity(0.16))
					.overlay(Capsule().strokeBorder(MachmanColors.selection.opacity(0.35)))
			} else {
				Capsule().fill(Color.primary.opacity(
					hovering ? MachmanColors.hoverOverlay : 0.04))
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
