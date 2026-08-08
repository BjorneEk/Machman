//
//  MachmanButtonStyle.swift
//  MachmanUI
//
//  The standard Machman button treatment: borderless, with the hover-lightening rounded
//  background macOS gives toolbar buttons for free — reproduced here so every button in the
//  app can have it. Never tints destructive buttons red; the role is semantic only.
//

import SwiftUI

public struct MachmanButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	public init() {}

	public func makeBody(configuration: Configuration) -> some View {
		Styled(configuration: configuration, isEnabled: isEnabled)
	}

	// Hover state needs @State, and a ButtonStyle struct is recreated on every render — so
	// the state lives in a nested view.
	private struct Styled: View {
		let configuration: Configuration
		let isEnabled: Bool
		@State private var hovering = false

		var body: some View {
			configuration.label
				.padding(.horizontal, 5)
				.padding(.vertical, 3)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(
							configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
				)
				.contentShape(RoundedRectangle(cornerRadius: 5))
				.opacity(isEnabled ? 1 : 0.4)
				.onHover { hovering = $0 && isEnabled }
				.animation(.easeOut(duration: 0.1), value: hovering)
		}
	}
}
