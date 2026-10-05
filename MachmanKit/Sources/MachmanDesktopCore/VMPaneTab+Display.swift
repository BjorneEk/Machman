//
//  VMPaneTab+Display.swift
//  MachmanDesktopCore
//
//  What a canvas tab is called and badged with, in one place (Q12): the canvas strip, the
//  drag ghost and the torn window's title read it. A port is named by its VM's boot mode,
//  as the tree names it; an SSH session by its CURRENT name, which lives in TerminalSessions,
//  not in the ref.
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMPaneTab {
	// `vm` is the tab's VM, `info` its listing: nil when the VM is gone or the list isn't
	// there (mid-reconnect), and a port then gets the neutral EFI naming by its config index.
	@MainActor
	public func title(vm: String, info: VMInfo?, sessions: TerminalSessions) -> String {
		switch self {
		case .config:
			return vm
		case .terminal(let ref):
			let mode = info?.boot.mode ?? .efi
			return info?.port(for: ref)?.displayName(mode: mode)
				?? ref.displayName(mode: mode)
		case .ssh(let ref):
			return sessions.sshSessionName(vm: vm, ref: ref)
		}
	}

	public var symbol: String {
		switch self {
		case .config:
			return MachmanSymbols.tabConfig
		case .terminal(let ref):
			return ref.kind == .console ? MachmanSymbols.serialConsole : MachmanSymbols.serialUart
		case .ssh:
			return MachmanSymbols.deviceSSHSetup
		}
	}
}
