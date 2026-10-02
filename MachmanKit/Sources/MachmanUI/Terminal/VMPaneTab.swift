//
//  VMPaneTab.swift
//  MachmanUI
//
//  What one canvas tab shows: the VM's configuration, one of its serial ports' terminals, or
//  an SSH session. CanvasState lays these out in panes and persists them (its Codable
//  extension); TerminalSessions keys the live terminal controllers by them.
//

import Foundation

// Terminal tabs are keyed by their stable port ref. SSH tabs are ephemeral sessions (fresh
// UUID per open, stripped from persistence — see SSHSessionRef).
public enum VMPaneTab: Hashable, Sendable {
	case config
	case terminal(SerialPortRef)
	case ssh(SSHSessionRef)
}
