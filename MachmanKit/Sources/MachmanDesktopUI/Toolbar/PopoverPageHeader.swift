//
//  PopoverPageHeader.swift
//  MachmanDesktopUI
//
//  A popover sub-page's header (Q12): the back chevron and the page's title. The New Disk,
//  New VM and macOS pages share it; each puts its divider under it.
//

import SwiftUI
import MachmanUI

struct PopoverPageHeader: View {
	let title: String
	let back: () -> Void

	var body: some View {
		HStack(spacing: 6) {
			Button(action: back) {
				Image(systemName: MachmanSymbols.back)
					.font(.system(size: 10, weight: .bold))
			}
			.buttonStyle(.plain)
			.machmanHoverable()
			.help("Back")
			.accessibilityLabel("Back")
			Text(title)
				.font(.system(size: 12, weight: .semibold))
			Spacer()
		}
		.padding(8)
	}
}
