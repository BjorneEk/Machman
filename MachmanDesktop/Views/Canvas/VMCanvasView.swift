//
//  VMCanvasView.swift
//  MachmanDesktop
//
//  The editor-style canvas for one VM (1.0.4 UI): up to three side-by-side panes, each with
//  its own tab strip over the active tab's content (config tab or a serial terminal), split
//  by draggable dividers whose fractions persist per VM via CanvasStateStore. Layout is the
//  CanvasState value; live terminals stay in TerminalSessions and are created lazily when a
//  pane first shows their tab (spinner covers the gap). Drag-reorder and tear-off arrive in
//  later slices.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMCanvasView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	@ObservedObject var profiles: TerminalProfileStore
	let vm: VMInfo
	// Divider drags apply fractions absolutely from the drag-start snapshot.
	@State private var dragBaseFractions: [Double]?
	@Environment(\.machmanTheme) private var theme

	private static let dividerWidth: CGFloat = 5

	private var canvas: CanvasState { canvases.canvas(for: vm.name) }

	var body: some View {
		let canvas = self.canvas
		GeometryReader { geo in
			HStack(spacing: 0) {
				ForEach(Array(canvas.panes.enumerated()), id: \.element.id) { index, pane in
					paneView(pane, activePane: pane.id == canvas.activePaneID)
						.frame(width: paneWidth(
							index, canvas: canvas, totalWidth: geo.size.width))
					if index < canvas.panes.count - 1 {
						paneDivider(index, totalWidth: geo.size.width)
					}
				}
			}
		}
		.onAppear { ensureConfigTab() }
		.onChange(of: vm.name) { ensureConfigTab() }
	}

	// A canvas with nothing open shows the config tab (fresh VM, or everything closed).
	private func ensureConfigTab() {
		if canvases.canvas(for: vm.name).allOpenTabs.isEmpty {
			mutate { $0.open(.config) }
		}
	}

	private func mutate(_ change: (inout CanvasState) -> Void) {
		var c = canvases.canvas(for: vm.name)
		change(&c)
		canvases.setCanvas(c, for: vm.name)
	}

	// MARK: - Layout

	private func paneWidth(_ index: Int, canvas: CanvasState, totalWidth: CGFloat) -> CGFloat {
		let available = max(0, totalWidth
			- CGFloat(canvas.panes.count - 1) * Self.dividerWidth)
		let fraction = canvas.fractions.indices.contains(index)
			? canvas.fractions[index] : 1.0 / Double(canvas.panes.count)
		return available * CGFloat(fraction)
	}

	private func paneDivider(_ index: Int, totalWidth: CGFloat) -> some View {
		Rectangle()
			.fill(Color.primary.opacity(0.08))
			.frame(width: 1)
			.frame(width: Self.dividerWidth)
			.contentShape(Rectangle())
			.gesture(
				DragGesture(coordinateSpace: .global)
					.onChanged { value in
						let base = dragBaseFractions ?? canvas.fractions
						if dragBaseFractions == nil { dragBaseFractions = base }
						guard base.indices.contains(index) else { return }
						let available = max(1, totalWidth
							- CGFloat(canvas.panes.count - 1) * Self.dividerWidth)
						let delta = Double(value.translation.width / available)
						mutate { $0.setFraction(base[index] + delta, at: index) }
					}
					.onEnded { _ in dragBaseFractions = nil }
			)
	}

	// MARK: - Pane

	private func paneView(_ pane: CanvasPane, activePane: Bool) -> some View {
		VStack(spacing: 0) {
			paneStrip(pane, activePane: activePane)
			Divider()
			paneContent(pane)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				// Drop into a pane's content moves the tab into that pane (appended).
				.dropDestination(for: VMPaneTab.self) { dropped, _ in
					guard let moved = dropped.first else { return false }
					mutate { c in
						let count = c.panes.first { $0.id == pane.id }?.tabs
							.filter { $0 != moved }.count ?? 0
						c.move(moved, toPane: pane.id, at: count)
					}
					return true
				}
		}
	}

	private func paneStrip(_ pane: CanvasPane, activePane: Bool) -> some View {
		HStack(spacing: 2) {
			ForEach(pane.tabs, id: \.self) { tab in
				tabItem(tab, active: pane.active == tab && activePane,
					current: pane.active == tab)
					.draggable(tab)
					// Drop ON a tab inserts at its position (index computed without the
					// moved tab — CanvasState.move's drag semantics).
					.dropDestination(for: VMPaneTab.self) { dropped, _ in
						guard let moved = dropped.first, moved != tab else { return false }
						mutate { c in
							guard let paneID = c.pane(holding: tab),
								let target = c.panes.first(where: { $0.id == paneID }),
								var index = target.tabs.firstIndex(of: tab) else { return }
							if let mIdx = target.tabs.firstIndex(of: moved), mIdx < index {
								index -= 1
							}
							c.move(moved, toPane: paneID, at: index)
						}
						return true
					}
			}
			Spacer(minLength: 0)
				// Drop on the empty strip area appends to this pane.
				.dropDestination(for: VMPaneTab.self) { dropped, _ in
					guard let moved = dropped.first else { return false }
					mutate { c in
						let count = c.panes.first { $0.id == pane.id }?.tabs
							.filter { $0 != moved }.count ?? 0
						c.move(moved, toPane: pane.id, at: count)
					}
					return true
				}
			IconButton(
				symbol: MachmanSymbols.splitRight, tooltip: "Split right",
				font: .caption, flat: true
			) {
				if let tab = pane.active {
					mutate { $0.split(tab, trailing: true) }
				}
			}
			.disabled(canvas.panes.count >= CanvasState.maxPanes || pane.tabs.count < 1)
		}
		.padding(.horizontal, 6)
		.frame(height: 32)
	}

	// A tab: select button + close button, never nested (reliable hit targets). The active
	// tab of the ACTIVE pane gets the full fill; the current tab of an inactive pane a
	// lighter one.
	private func tabItem(_ tab: VMPaneTab, active: Bool, current: Bool) -> some View {
		HStack(spacing: 4) {
			Button {
				mutate { $0.activate(tab) }
			} label: {
				HStack(spacing: 5) {
					switch tab {
					case .config:
						Image(systemName: MachmanSymbols.tabConfig)
							.font(.caption)
					case .terminal(let ref):
						Image(systemName: ref.kind == .console
							? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
							.font(.caption)
						Text(displayName(ref)).font(.callout).lineLimit(1)
					}
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(tab == .config ? "Configuration" : "")
			Button {
				close(tab)
			} label: {
				Image(systemName: MachmanSymbols.closeTab)
					.font(.caption2)
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help("Close tab")
		}
		.padding(.horizontal, 8)
		.frame(height: 24)
		.background(RoundedRectangle(cornerRadius: 5, style: .continuous)
			.fill(Color.primary.opacity(active ? 0.12 : (current ? 0.05 : 0))))
	}

	private func close(_ tab: VMPaneTab) {
		if case .terminal(let ref) = tab {
			sessions.dropController(vm: vm.name, ref: ref)
		}
		mutate { $0.close(tab) }
	}

	// MARK: - Content

	@ViewBuilder
	private func paneContent(_ pane: CanvasPane) -> some View {
		switch pane.active {
		case nil:
			Text("No tab open")
				.foregroundColor(.secondary)
		case .config:
			VMConfigTabView(vm: vm, viewModel: viewModel)
		case .terminal(let ref):
			terminalContent(ref: ref)
		}
	}

	// The socket exists only while the VM serves this port. Stopped → placeholder.
	// Running → ensure the controller (built off the click, spinner covers) then render.
	@ViewBuilder
	private func terminalContent(ref: SerialPortRef) -> some View {
		if let socket = socketPath(ref: ref) {
			Group {
				if let controller = sessions.controller(vm: vm.name, ref: ref) {
					SerialTerminalHost(controller: controller)
						.id(ObjectIdentifier(controller))   // swap the view on reloadTab
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.padding(6)
				} else {
					VStack(spacing: 10) {
						ProgressView()
						Text("Connecting to \(guestName(ref: ref))…")
							.foregroundColor(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.onAppear {
				let vmName = vm.name
				let canvases = canvases
				sessions.ensureController(
					vm: vmName, ref: ref, socketPath: socket,
					profile: profiles.profile(vm: vmName, ref: ref),
					stillWanted: {
						canvases.canvas(for: vmName).allOpenTabs.contains(.terminal(ref))
					})
			}
		} else {
			VStack(spacing: 8) {
				Image(systemName: ref.kind == .console
					? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("Start the VM to open \(guestName(ref: ref)).")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	// MARK: - Port helpers

	private func port(ref: SerialPortRef) -> SerialPortInfo? {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		return ports?.first(where: { $0.index == ref.index })
	}

	private func socketPath(ref: SerialPortRef) -> String? {
		port(ref: ref)?.socketPath
	}

	private func guestName(ref: SerialPortRef) -> String {
		port(ref: ref)?.guestDevice ?? ref.guestDevice(macGuest: vm.boot.mode == .macOS)
	}

	// Prefer the server's guest device name; fall back to a derived one if the list lags.
	private func displayName(_ ref: SerialPortRef) -> String {
		guestName(ref: ref)
	}
}
