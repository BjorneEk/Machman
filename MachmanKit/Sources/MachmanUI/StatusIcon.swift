//
//  StatusIcon.swift
//  MachmanUI
//
//  One VM's state as a glyph (the agent menu's VM rows): macwindow (running, window open),
//  terminal (running headless), pause otherwise; a safe run adds the shield badge.
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
			.foregroundColor(state.isRunning ? MachmanColors.stateRunning : .primary)
			.overlay(alignment: .bottomTrailing) {
				// The safe-run badge. Menus may flatten the yellow to a template — the
				// shield shape still reads.
				if safeRun {
					Image(systemName: MachmanSymbols.safe)
						.font(.system(size: 8, weight: .bold))
						.foregroundColor(MachmanColors.safeMode)
						.offset(x: 3, y: 2)
				}
			}
	}

	private var symbol: String {
		guard state.isRunning else { return MachmanSymbols.vmStopped }
		return windowOpen ? MachmanSymbols.vmRunningWindowed : MachmanSymbols.vmRunningHeadless
	}
}
