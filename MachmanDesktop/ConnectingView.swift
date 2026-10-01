//
//  ConnectingView.swift
//  MachmanDesktop
//
//  Shown while the app has no daemon connection: spinner during attempts, and a clear
//  retry/launch path when the daemon can't be reached.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

struct ConnectingView: View {
	@ObservedObject var connection: DaemonConnection

	var body: some View {
		VStack(spacing: 16) {
			switch connection.status {
			case .connecting:
				ProgressView()
				Text("Connecting to Machman Agent…")
					.foregroundColor(.secondary)
			case .unavailable(let problem):
				Image(systemName: MachmanSymbols.daemonUnreachable)
					.font(.largeTitle)
					.foregroundColor(.secondary)
				Text("The Machman daemon is not reachable")
					.font(.title3)
				Text(problem.detail)
					.font(.caption)
					.foregroundColor(.secondary)
					.textSelection(.enabled)
				if connection.loginItemNeedsApproval {
					Text("Machman Agent is registered as a login item but needs your approval "
						+ "in System Settings.")
						.font(.caption)
						.foregroundColor(.secondary)
					Button("Open Login Items Settings") {
						connection.openLoginItemsSettings()
					}
				}
				HStack {
					Button("Launch Daemon") {
						connection.launchDaemon()
						connection.retry()
					}
					Button("Retry") {
						connection.retry()
					}
				}
			case .connected:
				EmptyView()
			}
		}
		.frame(minWidth: 480, minHeight: 320)
	}
}
