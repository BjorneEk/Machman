//
//  StatusIcon.swift
//  MachmanUI
//
//  One VM's state as a glyph: blue macwindow (running, console open), blue terminal (running
//  headless), pause otherwise. safeRun is the reserved yellow-shield slot (phase 6).
//

import SwiftUI
import MachmanAPI

public struct StatusIcon: View {
	private let state: VMState
	private let consoleOpen: Bool
	private let safeRun: Bool

	public init(state: VMState, consoleOpen: Bool, safeRun: Bool = false) {
		self.state = state
		self.consoleOpen = consoleOpen
		self.safeRun = safeRun
	}

	public var body: some View {
		Image(systemName: symbol)
			.foregroundColor(state.isRunning ? .blue : .primary)
	}

	private var symbol: String {
		guard state.isRunning else { return MachmanSymbols.vmStopped }
		return consoleOpen ? MachmanSymbols.vmRunningWindowed : MachmanSymbols.vmRunningHeadless
	}
}
