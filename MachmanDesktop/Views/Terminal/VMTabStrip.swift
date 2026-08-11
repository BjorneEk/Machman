//
//  VMTabStrip.swift
//  MachmanDesktop
//
//  The browser-like tab bar atop a VM's pane: a fixed config tab (gear, never closable) followed
//  by one closable tab per open serial terminal. Selecting switches the active tab; the X closes
//  it (which disconnects the terminal — a connection lives exactly as long as its tab).
//
//  A plain HStack with a fixed height (NOT a ScrollView, which is greedy vertically and delays
//  clicks) and plain Buttons — select and close are separate buttons, never nested — so every hit
//  target is reliable. The active tab gets a square fill.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMTabStrip: View {
	let vm: VMInfo
	@ObservedObject var sessions: TerminalSessions

	var body: some View {
		let state = sessions.state(vm.name)
		HStack(spacing: 2) {
			configTab(active: state.active == .config)
			ForEach(state.openPorts, id: \.self) { ref in
				terminalTab(ref: ref, active: state.active == .terminal(ref))
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 6)
		.frame(height: 32)
	}

	private func configTab(active: Bool) -> some View {
		Button {
			sessions.setActive(.config, for: vm.name)
		} label: {
			Image(systemName: MachmanSymbols.tabConfig)
				.frame(width: 44, height: 24)
				.contentShape(Rectangle())
				.background(active ? Color.primary.opacity(0.12) : Color.clear)
		}
		.buttonStyle(.plain)
		.help("Configuration")
	}

	private func terminalTab(ref: SerialPortRef, active: Bool) -> some View {
		HStack(spacing: 4) {
			Button {
				sessions.setActive(.terminal(ref), for: vm.name)
			} label: {
				HStack(spacing: 5) {
					Image(systemName: ref.kind == .console
						? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
						.font(.caption)
					Text(displayName(ref)).font(.callout).lineLimit(1)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			Button {
				sessions.closeTab(vm: vm.name, ref: ref)
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
		.background(active ? Color.primary.opacity(0.12) : Color.clear)
	}

	// Prefer the server's guest device name; fall back to a derived one if the port list lags.
	private func displayName(_ ref: SerialPortRef) -> String {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		if let p = ports?.first(where: { $0.index == ref.index }) { return p.guestDevice }
		return ref.guestDevice(macGuest: vm.boot.mode == .macOS)
	}
}
