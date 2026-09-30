//
//  TerminalController.swift
//  MachmanDesktopCore
//
//  What TerminalSessions needs from a live terminal: its connection lifecycle, live profile
//  changes and its transcript — nothing about how it is drawn. The app's SwiftTerm-backed
//  SerialTerminalController (MachmanDesktopUI) conforms; the session registry makes them
//  through an injected factory, so tests drive tab lifecycles with a recording fake.
//

import Foundation
import MachmanUI

@MainActor
public protocol TerminalController: AnyObject {
	var connected: Bool { get }
	// The startup-only settings baked in at creation (a Reload applies changed ones).
	var startupSignature: TerminalStartupSignature { get }
	// Idempotent per socket: a controller connects once; a new socket is a new controller.
	func connect(path: String)
	func connect(stream: TerminalByteStream)
	func disconnect()
	func applyLive(_ profile: TerminalProfile)
	// Machman's own line in the terminal (session boundaries).
	func note(_ text: String)
	// The live connection's transcript, or the last one's after it closed.
	func transcript() -> Data
}
