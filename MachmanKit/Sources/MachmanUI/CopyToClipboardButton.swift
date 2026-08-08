//
//  CopyToClipboardButton.swift
//  MachmanUI
//
//  Copies a string to the general pasteboard; flips its glyph to a checkmark briefly so the
//  click visibly did something.
//

import SwiftUI
import AppKit

public struct CopyToClipboardButton: View {
	private let value: String
	private let tooltip: String
	@State private var copied = false

	public init(_ value: String, tooltip: String = "Copy") {
		self.value = value
		self.tooltip = tooltip
	}

	public var body: some View {
		IconButton(
			symbol: copied ? MachmanSymbols.copyDone : MachmanSymbols.copy,
			tooltip: tooltip
		) {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(value, forType: .string)
			copied = true
			Task {
				try? await Task.sleep(for: .seconds(1.5))
				copied = false
			}
		}
	}
}
