//
//  VMListViewModel+Transcript.swift
//  MachmanDesktopCore
//
//  File ▸ Save Terminal…'s question (H63): the panel suggests "<vm> <tab>.log", from the tab
//  the saved terminal serves — a port as the tree and the canvas name it, an SSH tab by its
//  session's current name. MachmanDesktopUI asks it with a save sheet.
//

import Foundation
import MachmanUI

extension VMListViewModel {
	public func transcriptSaveRequest(for terminal: any TerminalController) -> SavePanelRequest {
		guard let held = terminals.tab(of: terminal) else { return .anyTranscript }
		let info = vms.first { $0.name == held.vm }
		return .terminalTranscript(
			vm: held.vm, tab: held.tab.title(vm: held.vm, info: info, sessions: terminals))
	}
}
