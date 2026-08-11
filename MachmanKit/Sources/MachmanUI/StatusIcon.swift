//
//  StatusIcon.swift
//  MachmanUI
//
//  One VM's state as a glyph: blue macwindow (running, window open), blue terminal (running
//  headless), pause otherwise. safeRun is the reserved yellow-shield slot (phase 6).
//

import SwiftUI
import MachmanAPI

public struct StatusIcon: View {
	private let state: VMState
	private let windowOpen: Bool
	private let safeRun: Bool

	public init(state: VMState, windowOpen: Bool, safeRun: Bool = false) {
		self.state = state
		self.windowOpen = windowOpen
		self.safeRun = safeRun
	}

	public var body: some View {
		Image(systemName: symbol)
			.foregroundColor(state.isRunning ? .blue : .primary)
			.overlay(alignment: .bottomTrailing) {
				// The safe-run badge. Menus may flatten the yellow to a template — the
				// shield shape still reads.
				if safeRun {
					Image(systemName: MachmanSymbols.safe)
						.font(.system(size: 8, weight: .bold))
						.foregroundColor(.yellow)
						.offset(x: 3, y: 2)
				}
			}
	}

	private var symbol: String {
		guard state.isRunning else { return MachmanSymbols.vmStopped }
		return windowOpen ? MachmanSymbols.vmRunningWindowed : MachmanSymbols.vmRunningHeadless
	}
}
