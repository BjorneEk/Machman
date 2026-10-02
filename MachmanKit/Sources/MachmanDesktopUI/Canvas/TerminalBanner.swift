//
//  TerminalBanner.swift
//  MachmanDesktopUI
//
//  The one-line notice over a terminal whose session isn't live (an ssh session that ended, a
//  serial socket that closed or refused) with the action that brings it back. It sits at the
//  top of the terminal, which stays readable under it.
//

import SwiftUI

struct TerminalBanner<Actions: View>: View {
	let text: String
	let actions: Actions

	init(_ text: String, @ViewBuilder actions: () -> Actions) {
		self.text = text
		self.actions = actions()
	}

	var body: some View {
		HStack(spacing: 8) {
			Text(text)
				.font(.caption)
			actions
				.controlSize(.small)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 5)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
		.padding(.top, 10)
	}
}
