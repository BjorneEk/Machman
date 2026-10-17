//
//  IconButton.swift
//  MachmanUI
//
//  The standard Machman button: an icon (optionally with a text label), a tooltip, and the
//  MachmanButtonStyle hover treatment. An icon-only button speaks its name to VoiceOver,
//  never the symbol's name ("arrow clockwise") (H23). A button the VM refuses now keeps its
//  name and carries the reason as its tooltip, which VoiceOver reads as the hint (H57).
//

import SwiftUI

public struct IconButton: View {
	private let symbol: String
	private let name: String
	private let disabledReason: String?
	private let text: String?
	private let font: Font?
	private let flat: Bool
	private let role: ButtonRole?
	private let action: () -> Void

	// `name` is what the button does: its label, and its tooltip while it is on offer. A
	// `disabledReason` dims it and takes the tooltip, so the action keeps its name ("Delete
	// disk…", never "Stop the VM to remove its disks").
	public init(
		symbol: String,
		name: String,
		disabledReason: String?,
		text: String? = nil,
		font: Font? = nil,
		flat: Bool = false,
		role: ButtonRole? = nil,
		action: @escaping () -> Void
	) {
		self.symbol = symbol
		self.name = name
		self.disabledReason = disabledReason
		self.text = text
		self.font = font
		self.flat = flat
		self.role = role
		self.action = action
	}

	// A button never refused for a reason of its own: the tooltip is its name.
	public init(
		symbol: String,
		tooltip: String,
		text: String? = nil,
		font: Font? = nil,
		flat: Bool = false,
		role: ButtonRole? = nil,
		action: @escaping () -> Void
	) {
		self.init(
			symbol: symbol, name: tooltip, disabledReason: nil, text: text, font: font,
			flat: flat, role: role, action: action)
	}

	public var body: some View {
		Button(role: role, action: action) {
			if let text {
				Label(text, systemImage: symbol)
			} else {
				Image(systemName: symbol)
			}
		}
		.font(font)
		.buttonStyle(MachmanButtonStyle(flat: flat))
		.disabled(disabledReason != nil)
		// On macOS the tooltip is the accessibility help VoiceOver reads after the name.
		.help(disabledReason ?? name)
		.accessibilityLabel(text ?? name)
	}
}
