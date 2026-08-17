//
//  InspectorBlocks.swift
//  MachmanUI
//
//  Shared inspector building blocks that had grown by copy-paste: the host-gate section
//  (three verbatim copies), the copyable command block (five near-identical ones), and the
//  Setup Guide button. One home, so the next inspector composes instead of pasting.
//

import SwiftUI
import MachmanAPI

// MARK: - Unavailable gate ---------------------------------------------------------------------

// Why something configured on this VM cannot be used on this host — leads the inspector so
// the reason is read before the settings below it.
public struct UnavailableGateSection: View {
	private let info: UnavailabilityInfo

	public init(_ info: UnavailabilityInfo) {
		self.info = info
	}

	public var body: some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 3) {
					Text("Unavailable on this host")
						.fontWeight(.medium)
					Text(info.message)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			} icon: {
				Image(systemName: MachmanSymbols.warning)
					.foregroundStyle(MachmanColors.warning)
			}
		}
	}
}

// MARK: - Command block ------------------------------------------------------------------------

// A command the user copies into a guest: selectable monospaced text beside a copy button,
// on the standard subtle card.
public struct CommandBlock: View {
	private let command: String
	private let tooltip: String

	public init(_ command: String, tooltip: String = "Copy command") {
		self.command = command
		self.tooltip = tooltip
	}

	public var body: some View {
		HStack {
			Text(command)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer()
			CopyToClipboardButton(command, tooltip: tooltip)
		}
		.padding(6)
		.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
	}
}

// MARK: - Guide button -------------------------------------------------------------------------

// The "Setup Guide…" opener; the sheet itself stays with the caller.
public struct GuideButton: View {
	private let isPresented: Binding<Bool>
	private let help: String?

	public init(isPresented: Binding<Bool>, help: String? = nil) {
		self.isPresented = isPresented
		self.help = help
	}

	public var body: some View {
		Button {
			isPresented.wrappedValue = true
		} label: {
			Label("Setup Guide…", systemImage: MachmanSymbols.help)
		}
		.help(help ?? "")
	}
}
