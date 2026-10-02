//
//  IconButton.swift
//  MachmanUI
//
//  The standard Machman button: an icon (optionally with a text label), a tooltip, and the
//  MachmanButtonStyle hover treatment. An icon-only button speaks its tooltip to VoiceOver,
//  never the symbol's name ("arrow clockwise") (H23).
//

import SwiftUI

public struct IconButton: View {
	private let symbol: String
	private let tooltip: String
	private let text: String?
	private let font: Font?
	private let flat: Bool
	private let role: ButtonRole?
	private let action: () -> Void

	public init(
		symbol: String,
		tooltip: String,
		text: String? = nil,
		font: Font? = nil,
		flat: Bool = false,
		role: ButtonRole? = nil,
		action: @escaping () -> Void
	) {
		self.symbol = symbol
		self.tooltip = tooltip
		self.text = text
		self.font = font
		self.flat = flat
		self.role = role
		self.action = action
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
		.help(tooltip)
		.accessibilityLabel(text ?? tooltip)
	}
}
