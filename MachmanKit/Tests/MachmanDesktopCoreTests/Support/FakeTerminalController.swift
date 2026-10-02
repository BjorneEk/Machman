//
//  FakeTerminalController.swift
//  MachmanDesktopCoreTests
//
//  A TerminalController that records instead of connecting: what TerminalSessions creates
//  in the desktop tests (never a socket, never a PTY process).
//

import Foundation
import MachmanUI
@testable import MachmanDesktopCore

@MainActor
final class FakeTerminalController: TerminalController {
	private(set) var connected = false
	let startupSignature: TerminalStartupSignature
	private(set) var connectedPaths: [String] = []
	private(set) var disconnects = 0
	private(set) var liveApplies = 0
	private(set) var notes: [String] = []
	// A socket that refuses, a process that can't start: connects are recorded, never made.
	var refusesConnect = false

	init(profile: TerminalProfile) {
		startupSignature = profile.startupSignature
	}

	func connect(path: String) {
		connectedPaths.append(path)
		connected = !refusesConnect
	}

	func connect(stream: TerminalByteStream) {
		connected = !refusesConnect   // the stream is never started: no ssh process
	}

	func disconnect() {
		disconnects += 1
		connected = false
	}

	func applyLive(_ profile: TerminalProfile) {
		liveApplies += 1
	}
	func note(_ text: String) { notes.append(text) }
	func transcript() -> Data { Data() }
}
