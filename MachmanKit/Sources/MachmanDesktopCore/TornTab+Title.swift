//
//  TornTab+Title.swift
//  MachmanDesktopCore
//
//  What a torn-off window calls itself (T13): its VM's name for the preview tab, as the canvas
//  tab names it; "<VM> — <tab>" for a terminal or session, the tab named as the canvas names
//  it (VMPaneTab.title), so a session's window follows its renames.
//

import Foundation
import MachmanAPI
import MachmanUI

extension TornTab {
	// `vms` is the current list, nil mid-reconnect: a gone or unknown VM gets the neutral
	// EFI port naming (and the ref's config index).
	@MainActor
	public func windowTitle(vms: [VMInfo]?, terminals: TerminalSessions) -> String {
		let name = tab.title(
			vm: vm, info: vms?.first(where: { $0.name == vm }), sessions: terminals)
		switch tab {
		case .config:
			return name
		case .terminal, .ssh:
			return "\(vm) — \(name)"
		}
	}
}
