//
//  ConnectingView.swift
//  MachmanDesktop
//
//  Shown while the app has no daemon connection: DaemonConnection's state and actions handed
//  to ConnectionStatusView (MachmanDesktopUI, where the render tool can draw it).
//

import SwiftUI
import MachmanDesktopUI

struct ConnectingView: View {
	@ObservedObject var connection: DaemonConnection

	var body: some View {
		ConnectionStatusView(
			status: connection.status,
			loginItemNeedsApproval: connection.loginItemNeedsApproval,
			retry: { connection.retry() },
			launchDaemon: { connection.launchAndRetry() },
			openLoginItems: { connection.openLoginItemsSettings() })
	}
}
