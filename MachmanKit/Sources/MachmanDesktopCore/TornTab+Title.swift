//
//  TornTab+Title.swift
//  MachmanDesktopCore
//
//  What a torn-off window calls itself (T13): its VM's name for the preview tab, as the canvas
//  tab names it; "<VM> — <tab>" for a terminal or session. A port names itself by the live
//  VM's boot mode, and an ssh session by its CURRENT name — renames live in TerminalSessions,
//  not in the ref, so the window must read them there to follow a rename.
//

import Foundation
import MachmanAPI
import MachmanUI

extension TornTab {
	// `vms` is the current list, nil mid-reconnect: a gone or unknown VM gets the neutral
	// EFI port naming (and the ref's config index).
	@MainActor
	public func windowTitle(vms: [VMInfo]?, terminals: TerminalSessions) -> String {
		switch tab {
		case .config:
			return vm
		case .terminal(let ref):
			let info = vms?.first(where: { $0.name == vm })
			let mode = info?.boot.mode ?? .efi
			let name = info?.port(for: ref)?.displayName(mode: mode)
				?? ref.displayName(mode: mode)
			return "\(vm) — \(name)"
		case .ssh(let ref):
			return "\(vm) — \(terminals.sshSessionName(vm: vm, ref: ref))"
		}
	}
}
