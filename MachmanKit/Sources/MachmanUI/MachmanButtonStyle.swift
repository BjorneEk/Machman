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
	private let flat: Bool

	// flat: no resting tint — for controls that read as buttons without one (table deletes,
	// copy buttons). Everything else gets a subtle resting contrast so it looks pressable
	// before the pointer arrives.
	public init(flat: Bool = false) {
		self.flat = flat
	}

	public func makeBody(configuration: Configuration) -> some View {
		Styled(configuration: configuration, isEnabled: isEnabled, flat: flat)
	}

	// Hover state needs @State, and a ButtonStyle struct is recreated on every render — so
	// the state lives in a nested view.
	private struct Styled: View {
		let configuration: Configuration
		let isEnabled: Bool
		let flat: Bool
		@State private var hovering = false

		private var backgroundOpacity: Double {
			if configuration.isPressed { return 0.16 }
			if hovering { return flat ? 0.08 : 0.12 }
			return flat ? 0 : 0.06
		}

		var body: some View {
			configuration.label
				.padding(.horizontal, 5)
				.padding(.vertical, 3)
				.background(
					RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(backgroundOpacity))
				)
				.contentShape(RoundedRectangle(cornerRadius: 5))
				.opacity(isEnabled ? 1 : 0.4)
				.onHover { hovering = $0 && isEnabled }
				.animation(.easeOut(duration: 0.1), value: hovering)
		}
	}
}
