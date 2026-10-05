//
//  VMBusyRule.swift
//  MachmanUI
//
//  Unknown is busy (P37, V11): one rule for every surface that offers Start or a stop — the
//  desktop's (VMMenuRules, canStart, the Dock) and the menu-bar agent's (MenuBarRules). The
//  daemon lists a VM's state as unknown while Machman Agent hasn't reached its vmhost (an
//  adoption under way, or one that failed), precisely so that no client offers a second
//  Start: the VM may well be running. So, as for a VM whose vmhost stopped answering, Start
//  and the stop-first actions wait, and stopping is offered.
//

import Foundation
import MachmanAPI

extension VMInfo {
	// Running as last heard (starting, stopping and paused count), not answering, or unknown.
	public var mayBeRunning: Bool {
		state.isRunning || state == .unknown || isUnresponsive
	}

	// Why a VM whose state is unknown offers neither Start nor its stop-first actions.
	public static let unreachedHelp = "Wait for Machman Agent to reach this VM"
}
