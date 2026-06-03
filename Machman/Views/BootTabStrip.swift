//
//  BootTabStrip.swift
//  Machman
//
//  A two-tab strip for BootConfigView. Custom because SwiftUI's TabView cannot disable an
//  individual tab (needed once a VM has macOS installed and its boot mode is locked).
//

import SwiftUI

enum BootTab {
	case def
	case mac
}

struct BootTabStrip: View {
	@Binding var selection: BootTab
	var defaultDisabled: Bool
	var defaultDisabledHelp: String

	var body: some View {
		HStack(spacing: 4) {
			tabButton(.def, title: "default", systemImage: "power")
			tabButton(.mac, title: "macOS", systemImage: "apple.logo")
		}
	}

	@ViewBuilder
	private func tabButton(_ tab: BootTab, title: String, systemImage: String) -> some View {
		let disabled = (tab == .def && defaultDisabled)
		let button = Button(action: { selection = tab }) {
			Label(title, systemImage: systemImage)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(selection == tab ? Color.accentColor.opacity(0.18) : Color.clear)
				)
				.foregroundColor(disabled ? .secondary : .primary)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(disabled)

		if disabled {
			// .help may not fire on a disabled control; an enabled clear overlay carries the
			// tooltip instead (same .contentShape + .help idiom as ConfigVMDisksView).
			button.overlay(Color.clear.contentShape(Rectangle()).help(defaultDisabledHelp))
		} else {
			button
		}
	}
}

#Preview {
}
