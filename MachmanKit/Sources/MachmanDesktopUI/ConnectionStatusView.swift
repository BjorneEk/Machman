//
//  ConnectionStatusView.swift
//  MachmanDesktopUI
//
//  The main window while the app has no agent connection: a spinner while the connect loop
//  works and, once it stopped, what went wrong and what to do — the problem, a one-sentence
//  remedy, the underlying error, and Retry (plus Launch Daemon when the agent isn't there at
//  all). Stateless: the app's ConnectingView feeds it DaemonConnection's state.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

public struct ConnectionStatusView: View {
	private let status: ConnectionStatus
	private let loginItemNeedsApproval: Bool
	private let retry: @MainActor () -> Void
	private let launchDaemon: @MainActor () -> Void
	private let openLoginItems: @MainActor () -> Void

	public init(
		status: ConnectionStatus, loginItemNeedsApproval: Bool,
		retry: @escaping @MainActor () -> Void,
		launchDaemon: @escaping @MainActor () -> Void,
		openLoginItems: @escaping @MainActor () -> Void
	) {
		self.status = status
		self.loginItemNeedsApproval = loginItemNeedsApproval
		self.retry = retry
		self.launchDaemon = launchDaemon
		self.openLoginItems = openLoginItems
	}

	public var body: some View {
		VStack(spacing: 16) {
			switch status {
			case .connecting:
				ProgressView()
				Text("Connecting to Machman Agent…")
					.foregroundColor(.secondary)
			case .unavailable(let problem):
				unavailable(problem)
			case .connected:
				EmptyView()
			}
		}
		.padding(.horizontal, 24)
		.frame(minWidth: 480, minHeight: 320)
	}

	@ViewBuilder
	private func unavailable(_ problem: ConnectionProblem) -> some View {
		Image(systemName: MachmanSymbols.daemonUnreachable)
			.font(.largeTitle)
			.foregroundColor(.secondary)
		VStack(spacing: 8) {
			Text(problem.title)
				.font(.title3)
			if let hint = problem.hint {
				Text(hint)
					.font(.callout)
					.foregroundColor(.secondary)
			}
			Text(problem.detail)
				.font(.caption)
				.foregroundColor(.secondary)
				.textSelection(.enabled)
		}
		.multilineTextAlignment(.center)
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: 420)
		if loginItemNeedsApproval {
			Text("Machman Agent is registered as a login item but needs your approval "
				+ "in System Settings.")
				.font(.caption)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: 420)
			Button("Open Login Items Settings") { openLoginItems() }
		}
		HStack {
			// Launching helps only when nothing serves; a hung or other-version agent holds the
			// socket, and a second one would just concede to it.
			if problem.kind == .unreachable {
				Button("Launch Daemon") { launchDaemon() }
			}
			Button("Retry") { retry() }
		}
	}
}
