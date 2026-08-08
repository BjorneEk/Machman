//
//  ConnectingView.swift
//  Machman
//
//  Shown while the app has no daemon connection: spinner during attempts, and a clear
//  retry/launch path when the daemon can't be reached.
//

import SwiftUI
import MachmanUI

struct ConnectingView: View {
	@ObservedObject var connection: DaemonConnection

	var body: some View {
		VStack(spacing: 16) {
			switch connection.status {
			case .connecting:
				ProgressView()
				Text("Connecting to Machmand…")
					.foregroundColor(.secondary)
			case .unavailable(let reason):
				Image(systemName: MachmanSymbols.daemonUnreachable)
					.font(.largeTitle)
					.foregroundColor(.secondary)
				Text("The Machman daemon is not reachable")
					.font(.title3)
				Text(reason)
					.font(.caption)
					.foregroundColor(.secondary)
					.textSelection(.enabled)
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
