//
//  TerminalTabContent.swift
//  MachmanDesktopUI
//
//  One terminal tab's content, shared by the canvas panes and torn-off windows: the live
//  SwiftTerm view when the port has a socket (created lazily with a spinner over the gap, and
//  saying so when that socket closed or refused — T25), otherwise one sentence saying why there
//  is none (SerialTabState, T10). The controller comes from the app-scoped TerminalSessions,
//  so the same terminal reparents wherever the tab lives.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TerminalTabContent: View {
	@ObservedObject var sessions: TerminalSessions
	let profiles: TerminalProfileStore
	let vm: VMInfo
	let ref: SerialPortRef
	// Re-checked on the deferred creation turn — the tab may have closed meanwhile.
	let stillWanted: @MainActor () -> Bool
	@Environment(\.terminalDisconnectedGrace) private var disconnectedGrace

	var body: some View {
		switch SerialTabState(vm: vm, ref: ref) {
		case .live(let socket):
			live(socket: socket)
		case .waiting:
			VStack(spacing: 10) {
				ProgressView()
				Text("Waiting for \(guestName)…")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		case .startVM:
			placeholder("Start the VM to open \(guestName).")
		case .restartVM:
			placeholder("Restart the VM to open \(guestName).")
		case .disabled(let running):
			placeholder(running
				? "Enable \(guestName) and restart the VM to open it."
				: "Enable \(guestName) and start the VM to open it.")
		case .unavailable(let reason):
			placeholder("\(guestName) isn’t available on this Mac.", warning: true)
				.help(reason)
		}
	}

	private func live(socket: String) -> some View {
		Group {
			if let controller = sessions.serialTerminal(vm: vm.name, ref: ref) {
				SerialSessionSurface(
					controller: controller, vmIsStopping: vm.state == .stopping,
					grace: disconnectedGrace,
					reconnect: { reconnect(socket: socket) })
					.id(ObjectIdentifier(controller))   // swap the view on reloadTab
			} else {
				VStack(spacing: 10) {
					ProgressView()
					Text("Connecting to \(guestName)…")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear { ensureController(socket: socket) }
		// The port's socket moved while the tab stayed live (onAppear won't run again): a
		// controller left disconnected connects to the new one.
		.onChange(of: socket) { _, new in ensureController(socket: new) }
	}

	private func reconnect(socket: String) {
		sessions.reconnectSerial(vm: vm.name, ref: ref, socketPath: socket)
	}

	private func ensureController(socket: String) {
		// Deferred: reconnecting an existing controller flips its @Published `connected` —
		// publishing mid-view-update warns.
		let vmName = vm.name
		let profile = profiles.profile(vm: vmName, ref: ref)
		let stillWanted = stillWanted
		DispatchQueue.main.async { [weak sessions] in
			sessions?.ensureController(
				vm: vmName, ref: ref, socketPath: socket, profile: profile,
				stillWanted: stillWanted)
		}
	}

	// The port's symbol over one sentence; a host that can't attach the port gets the
	// warning triangle instead.
	private func placeholder(_ text: String, warning: Bool = false) -> some View {
		VStack(spacing: 8) {
			Image(systemName: warning ? MachmanSymbols.warning
				: ref.kind == .console ? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.largeTitle)
				.foregroundColor(warning ? MachmanColors.warning : .secondary)
			Text(text)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
		}
		.padding(.horizontal, 16)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var port: SerialPortInfo? { vm.port(for: ref) }

	private var guestName: String {
		port?.displayName(mode: vm.boot.mode) ?? ref.displayName(mode: vm.boot.mode)
	}
}

// Observes the controller, so a terminal whose socket closed or refused says so and offers to
// connect again (T25), where a dead terminal used to stay silently empty. The banner waits out
// a grace period: a normal stop closes the socket a moment before the list drops it, and the
// tab then shows why there is no terminal instead. The grace runs from when the controller
// disconnected, so a remount (a tear-off, a tab switch back) of a dead tab says so soon — but
// never before remountMinimum: a mount's own deferred reconnect (a VM just started again)
// lands first, and a banner that would vanish a frame later never draws.
struct SerialSessionSurface: View {
	@ObservedObject var controller: SerialTerminalController
	let vmIsStopping: Bool
	let grace: Duration
	let reconnect: () -> Void
	@State private var graceOver: Bool
	static let remountMinimum: Duration = .milliseconds(250)

	init(
		controller: SerialTerminalController, vmIsStopping: Bool, grace: Duration,
		reconnect: @escaping () -> Void
	) {
		self.controller = controller
		self.vmIsStopping = vmIsStopping
		self.grace = grace
		self.reconnect = reconnect
		_graceOver = State(initialValue: grace == .zero)
	}

	// How long the controller has been without a connection (zero while it has one).
	private var down: Duration {
		guard !controller.connected, let since = controller.disconnectedAt else { return .zero }
		return .now - since
	}

	var body: some View {
		SerialTerminalHost(controller: controller)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(6)
			.overlay(alignment: .top) {
				if graceOver, !controller.connected, !vmIsStopping {
					TerminalBanner("Disconnected.") {
						Button("Reconnect", action: reconnect)
					}
				}
			}
			// Restarted on every flip: a connection resets the grace, a drop starts it.
			.task(id: controller.connected) {
				guard grace > .zero else { return }
				graceOver = false
				guard !controller.connected else { return }
				try? await Task.sleep(for: max(grace - down, Self.remountMinimum))
				if !Task.isCancelled { graceOver = true }
			}
	}
}

// How long a serial terminal stays disconnected before its banner says so. Render scenes set
// zero, so a snapshot never depends on how long the render took.
private struct TerminalDisconnectedGraceKey: EnvironmentKey {
	static let defaultValue: Duration = .seconds(1)
}

extension EnvironmentValues {
	var terminalDisconnectedGrace: Duration {
		get { self[TerminalDisconnectedGraceKey.self] }
		set { self[TerminalDisconnectedGraceKey.self] = newValue }
	}
}
