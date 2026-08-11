//
//  VMTabStrip.swift
//  MachmanDesktop
//
//  The browser-like tab bar atop a VM's pane: a fixed config tab (gear, never closable) followed
//  by one closable tab per open serial terminal. Selecting switches the active tab; the X closes
//  it (which disconnects the terminal — a connection lives exactly as long as its tab). Ports are
//  opened as tabs from the sidebar, not here.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMTabStrip: View {
	let vm: VMInfo
	@ObservedObject var sessions: TerminalSessions

	var body: some View {
		let state = sessions.state(vm.name)
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 4) {
				configTab(active: state.active == .config)
				ForEach(state.openPorts, id: \.self) { ref in
					terminalTab(ref: ref, active: state.active == .terminal(ref))
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
		}
	}

	private func configTab(active: Bool) -> some View {
		Button {
			sessions.setActive(.config, for: vm.name)
		} label: {
			Image(systemName: MachmanSymbols.tabConfig)
				.frame(width: 40, height: 26)
				.background(tabBackground(active))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Configuration")
	}

	private func terminalTab(ref: SerialPortRef, active: Bool) -> some View {
		HStack(spacing: 5) {
			Image(systemName: ref.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.caption)
			Text(displayName(ref)).font(.callout).lineLimit(1)
			Button {
				sessions.closeTab(vm: vm.name, ref: ref)
			} label: {
				Image(systemName: MachmanSymbols.closeTab).font(.caption2)
			}
			.buttonStyle(.plain)
			.help("Close tab")
		}
		.padding(.horizontal, 8)
		.frame(height: 26)
		.background(tabBackground(active))
		.contentShape(Rectangle())
		.onTapGesture {
			sessions.setActive(.terminal(ref), for: vm.name)
		}
	}

	private func tabBackground(_ active: Bool) -> some View {
		RoundedRectangle(cornerRadius: 6)
			.fill(active ? Color.primary.opacity(0.1) : Color.clear)
	}

	// Prefer the server's guest device name; fall back to a derived one if the port list lags.
	private func displayName(_ ref: SerialPortRef) -> String {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		if let p = ports?.first(where: { $0.index == ref.index }) { return p.guestDevice }
		return ref.guestDevice(macGuest: vm.boot.mode == .macOS)
	}
}
