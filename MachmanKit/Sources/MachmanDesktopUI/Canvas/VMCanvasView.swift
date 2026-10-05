//
//  VMCanvasView.swift
//  MachmanDesktopUI
//
//  The editor-style canvas for one VM (1.0.4 UI, demo-parity): up to three panes with
//  Xcode-like tab strips, a custom drag system — live in-strip reorder, pull down (or off
//  the strip) to detach into a ghost with measured drop zones (move between panes, split a
//  new edge pane), release outside the canvas to tear the tab off into its own window —
//  and draggable pane dividers. The drag's rules are the CanvasTabDrag value (MachmanUI):
//  this view feeds it gestures and measured frames and applies what it decides. Layout is
//  the CanvasState value persisted per VM by CanvasStateStore; live terminals stay in
//  TerminalSessions and reparent wherever the tab goes.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

private let dividerWidth = MainWindowLayout.paneDivider

struct VMCanvasView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	@ObservedObject var profiles: TerminalProfileStore
	let vm: VMInfo

	// The in-flight tab drag: translation drives in-strip reorder until the tab detaches
	// (pulled down or off its strip), after which the ghost + drop zones take over.
	@State private var tabDrag: CanvasTabDrag?
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

		// The rects as the drag rules read them.
		var measured: CanvasTabDrag.Frames {
			CanvasTabDrag.Frames(canvasSize: canvasSize, panes: panes, strips: strips, tabs: tabs)
		}
	}
	@State private var frames = FrameStore()
	// A divider drag in flight: the canvas draws its fractions and stores them on release
	// (P9), so a drag event re-renders only this view, not the window and its menus. Gesture
	// state, so a drag SwiftUI cancels (its divider went with a closing pane) resets instead
	// of keeping the resize pointer up and handing its stale layout to the next drag (F18).
	@GestureState private var dividerDrag: CanvasDividerDrag?
	@Environment(\.machmanTheme) private var theme
	@Environment(\.openWindow) private var openWindow

	private var canvas: CanvasState { canvases.canvas(for: vm.name) }

	var body: some View {
		GeometryReader { geo in
			let c = canvas
			// Panes plus dividers always sum to the canvas width (L2).
			let widths = CanvasPaneLayout.widths(
				fractions: fractions(of: c), total: geo.size.width, divider: dividerWidth)
			HStack(spacing: 0) {
				ForEach(Array(c.panes.enumerated()), id: \.element.id) { index, pane in
					paneView(pane, canvas: c)
						.frame(width: widths.indices.contains(index) ? widths[index] : 0)
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
			// A fast drag outruns the 9 pt divider: its pointer stays until the release.
			.pointerStyle(dividerDrag != nil ? .columnResize : nil)
		}
		.coordinateSpace(name: "machman-canvas")
		.background(Color(nsColor: .underPageBackgroundColor))
		.modifier(TabCloseQuestion(viewModel: viewModel, window: nil))
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
				!viewModel.tornTabs.isOpen(vm: name, tab: .config) else { return }
			var canvas = canvases.canvas(for: name)
			canvas.open(.config)
			canvases.setCanvas(canvas, for: name)
		}
	}

	// The drag's fractions while one is in flight over this layout, else the stored ones.
	private func fractions(of c: CanvasState) -> [Double] {
		guard let drag = dividerDrag, drag.fits(c) else { return c.fractions }
		return drag.fractions
	}

	// The width a divider drag measures its movement against: the panes' total.
	private var dividerSpan: CGFloat {
		max(200, frames.canvasSize.width - dividerWidth * CGFloat(canvas.panes.count - 1))
	}

	private func mutate(_ change: (inout CanvasState) -> Void) {
		var c = canvases.canvas(for: vm.name)
		change(&c)
		canvases.setCanvas(c, for: vm.name)
	}

	// MARK: - Layout

	private func paneDivider(_ index: Int) -> some View {
		ZStack {
			Color.clear
			Rectangle()
				.fill(Color(nsColor: .separatorColor))
				.frame(width: 1)
		}
		.frame(width: dividerWidth)
		.contentShape(Rectangle())
		// The system's column-resize pointer, set by hover — not a push/pop that a divider
		// leaving mid-hover (a collapsed pane, a VM switch) leaves unbalanced (H43).
		.pointerStyle(.columnResize)
		.gesture(
			DragGesture(coordinateSpace: .named("machman-canvas"))
				.updating($dividerDrag) { value, drag, _ in
					if drag?.fits(canvas) != true {
						drag = CanvasDividerDrag(index: index, canvas: canvas)
					}
					drag?.update(translation: value.translation.width, available: dividerSpan)
				}
				.onEnded { value in
					// The gesture state has reset by now: the same drag, worked out again
					// from the layout it started on (the store wasn't written), is stored.
					var drag = CanvasDividerDrag(index: index, canvas: canvas)
					drag.update(translation: value.translation.width, available: dividerSpan)
					mutate { $0 = drag.committed(to: $0) }
				}
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
				// A click inside the pane makes it the active one (T23).
				.background(PaneClickWatcher {
					viewModel.paneClicked(pane.id, vm: vm.name)
				})
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
						closeAsks: viewModel.closeAsks(tab, vm: vm.name),
						tabStyle: theme.tabStyle,
						metrics: theme.metrics,
						onSelect: { viewModel.tabClicked(tab, vm: vm.name) },
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
			viewModel.paneClicked(pane.id, vm: vm.name)
		})
	}

	private func dragOffset(for tab: VMPaneTab) -> CGSize {
		tabDrag?.offset(for: tab) ?? .zero
	}

	// MARK: - Tab actions

	// A connected SSH session asks first (H42); every other tab closes at once.
	private func close(_ tab: VMPaneTab) {
		viewModel.requestCloseTab(tab, vm: vm.name)
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
		let payload = viewModel.tearOff(tab, vm: vm.name)
		DispatchQueue.main.async { openWindow(id: "torn-tab", value: payload) }
	}

	// MARK: - Drag logic (demo parity)

	// The rules live in CanvasTabDrag; a live reorder it reports moves the tab, animated,
	// before the drag state is stored, and the stored state animates when the tab detaches
	// or docks again (the ghost and drop zones fade, H50).
	private func updateTabDrag(tab: VMPaneTab, pane: UUID, value: DragGesture.Value) {
		var drag = tabDrag ?? CanvasTabDrag(
			tab: tab, paneID: pane, location: value.location,
			translation: value.translation)
		if let target = drag.update(
			location: value.location, translation: value.translation,
			canvas: canvas, frames: frames.measured) {
			let tab = drag.tab
			withAnimation(.snappy(duration: 0.18)) {
				mutate { $0.reorder(tab, to: target) }
			}
		}
		if CanvasTabDrag.detachChanges(from: tabDrag, to: drag) {
			withAnimation(.snappy(duration: 0.18)) { tabDrag = drag }
		} else {
			tabDrag = drag
		}
	}

	private func completeTabDrag() {
		guard let drag = tabDrag else { return }
		defer {
			withAnimation(.snappy(duration: 0.2)) { tabDrag = nil }
		}
		switch drag.release(canvas: canvas, frames: frames.measured) {
		case .stay:
			break
		case .tearOff:
			tearOff(drag.tab)
		case .move(let paneID, let index):
			mutate { $0.move(drag.tab, toPane: paneID, at: index) }
		case .split(let trailing):
			mutate { $0.split(drag.tab, trailing: trailing) }
		}
	}

	// MARK: - Drop-zone overlay + ghost

	private func dropZonesOverlay() -> some View {
		let zones = CanvasTabDrag.dropZones(canvas: canvas, frames: frames.measured)
		let location = tabDrag?.location ?? .zero
		let hovered = zones.first { $0.rect.contains(location) }?.zone
		// Full-size top-leading root: children are positioned by absolute canvas rects, so
		// the overlay must never be center-aligned by its container.
		return ZStack(alignment: .topLeading) {
			Color.clear
			ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
				let isHovered = hovered == zone.zone
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
						zoneLabel(zone.zone)
							.opacity(isHovered ? 1 : 0.55)
					}
					.frame(width: zone.rect.width, height: zone.rect.height)
					.offset(x: zone.rect.minX, y: zone.rect.minY)
					.animation(.easeOut(duration: 0.12), value: isHovered)
			}
			ghost(at: location)
		}
		.allowsHitTesting(false)
	}

	@ViewBuilder
	private func zoneLabel(_ zone: CanvasTabDrag.Zone) -> some View {
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
			// The configuration may live in a torn window: focus that, never a second copy.
			Button {
				if let torn = viewModel.revealTab(.config, vm: vm.name) {
					openWindow(id: "torn-tab", value: torn)
				}
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
		tab.symbol
	}

	private func tabTitle(_ tab: VMPaneTab) -> String {
		tab.title(vm: vm.name, info: vm, sessions: sessions)
	}
}
