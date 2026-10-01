//
//  FieldProblem.swift
//  MachmanDesktopUI
//
//  The one-sentence reason under a form field whose primary button is disabled — so a
//  disabled button never stays silent (PR8). Not focusable; wraps instead of truncating.
//

import SwiftUI
import MachmanUI

struct FieldProblem: View {
	let text: String

	init(_ text: String) {
		self.text = text
	}

	var body: some View {
		Label {
			Text(text)
		} icon: {
			Image(systemName: MachmanSymbols.warning)
				.foregroundStyle(MachmanColors.warning)
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
