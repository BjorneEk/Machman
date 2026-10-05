//
//  TreeSSHSection.swift
//  MachmanDesktopUI
//
//  The device tree's SSH section: its open sessions and the + that starts one
//  (VMDeviceTreeView).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TreeSSHSection: View {
	let ctx: TreeContext
	@Environment(\.machmanTheme) private var theme

	// Ephemeral SSH sessions, once the guest has reported a user: the section title IS
	// the command, the + opens a fresh session tab, and the open sessions are the
	// children — no devices behind them, nothing persists.
	// Present as soon as SSH is part of this VM — the installer attached, or state on
	// file — because this section is where SSH is set up, not just where sessions live.
	var body: some View {
		if ctx.vm.ssh?.configured == true {
			// Canvas tabs AND live torn-off windows: a detached session is still open, and
			// dropping it from this list would leave no way back to its window.
			let open = ctx.viewModel.openSSHSessions(vm: ctx.vm.name)
			let rows = ctx.sectionRows(.ssh, open) {
				ctx.matches(ctx.sessions.sshSessionName(vm: ctx.vm.name, ref: $0))
			}
			if ctx.shows(.ssh, rows: rows.count) {
				TreeGroup(.group("SSH"), symbol: MachmanSymbols.deviceSSHSetup,
					title: "SSH", count: open.count, selectable: true,
					folds: TreeSection.folds(rows: rows.count, previewing: false),
					isExpanded: ctx.groupBinding(.group("SSH")), menu: {
					// The + accessory's reliable twin — List group labels can swallow clicks.
					Button("New SSH Session") { openSSHSession() }
						.disabled(!sshSessionReady)
					if sshUnreachable || sshWaiting {
						Button("Check Connection") { ctx.viewModel.refreshSSH(ctx.vm.name) }
					}
				}, accessory: { sshSessionButton }) {
					ForEach(rows) { ref in
						sshSessionRow(ref)
					}
				}
			}
		}
	}

	private func sshSessionRow(_ ref: SSHSessionRef) -> some View {
		let torn = ctx.isTorn(.ssh(ref))
		return HStack(spacing: 6) {
			Image(systemName: MachmanSymbols.tabTerminal)
				.font(.system(size: theme.metrics.iconSize))
			Text(ctx.sessions.sshSessionName(vm: ctx.vm.name, ref: ref))
				.lineLimit(1)
			Spacer()
			if torn {
				Image(systemName: MachmanSymbols.newWindow)
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.help("Open in its own window")
			}
			// theme.accentColor: List rows reset Color.accentColor to the system's (H20).
			Circle().fill(theme.accentColor)
				.frame(width: 5, height: 5)
				.help("Session open")
		}
		.treeRow(.sshSession(ref), onClick: { ctx.clicked(.sshSession(ref)) }) {
			ctx.sshSessionMenu(ref, torn: torn)
		}
	}

	// A session can only start once the guest's sshd actually answers — the daemon's
	// reachability, not just an address (which appears long before sshd is listening).
	private var sshSessionReady: Bool {
		ctx.vm.state.isRunning && ctx.vm.ssh?.reachability == .ready
			&& SSHCommand.arguments(for: ctx.vm) != nil
	}

	private var sshUnreachable: Bool {
		ctx.vm.state.isRunning && ctx.vm.ssh?.reachability == .unreachable
	}

	private var sshWaiting: Bool {
		ctx.vm.state.isRunning && ctx.vm.ssh?.reachability == .waiting
	}

	// One control, three states: waiting on the guest, retry after giving up, or open a
	// session. The tooltip carries the reason, so the row itself stays quiet.
	@ViewBuilder
	private var sshSessionButton: some View {
		if sshWaiting {
			// No scaleEffect + fixed frame here: constraining a hosted AppKit
			// ProgressView to a size it also computes for itself makes it complain
			// ("maximum length … doesn't satisfy min <= max") on every layout pass.
			ProgressView()
				.controlSize(.small)
				.help("Waiting for sshd in the guest to answer…")
		} else if sshUnreachable {
			IconButton(symbol: MachmanSymbols.regenerate,
				tooltip: ctx.vm.ssh?.reachabilityDetail.map { "SSH: \($0) — try again" }
					?? "SSH did not answer — try again",
				font: .caption, flat: true) { ctx.viewModel.refreshSSH(ctx.vm.name) }
		} else {
			IconButton(symbol: MachmanSymbols.add,
				tooltip: sshSessionReady
					? "New SSH session tab"
					: "Sessions need the VM running and answering on port 22",
				font: .caption, flat: true) { openSSHSession() }
				.disabled(!sshSessionReady)
		}
	}

	private func openSSHSession() {
		guard SSHCommand.arguments(for: ctx.vm) != nil else { return }
		let ref = SSHSessionRef(title: ctx.viewModel.nextSSHSessionTitle(vm: ctx.vm.name))
		ctx.mutateCanvas { $0.open(.ssh(ref)) }
	}
}
