//
//  GlassSurface.swift
//  MachmanUI
//
//  The one place glass is implemented. On macOS 26+ this is real Liquid Glass
//  (glassEffect); earlier hosts get the material approximation (thin material + top
//  highlight + soft shadow). Content-layer surfaces only — toolbars/sidebars/popovers get
//  system glass on their own and must NOT use these (custom bar backgrounds break it).
//

import SwiftUI

public struct MachmanGlassSurface<S: InsettableShape>: ViewModifier {
	@Environment(\.machmanTheme) private var theme
	@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
	private let shape: S
	private let prominent: Bool
	// Optional wash: real Liquid Glass tinting on macOS 26, a fill overlay on the fallback.
	private let tint: Color?

	public init(shape: S, prominent: Bool = false, tint: Color? = nil) {
		self.shape = shape
		self.prominent = prominent
		self.tint = tint
	}

	public func body(content: Content) -> some View {
		if reduceTransparency {
			solid(content: content)
		} else if #available(macOS 26.0, *) {
			let glass: Glass = prominent ? .regular.interactive() : .regular
			content.glassEffect(tint.map { glass.tint($0) } ?? glass, in: shape)
		} else {
			legacy(content: content)
		}
	}

	// Reduce Transparency: an opaque surface with a hairline instead of any blur.
	private func solid(content: Content) -> some View {
		content
			.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
			.overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
	}

	private func legacy(content: Content) -> some View {
		content
			.background {
				shape.fill(theme.glass == .extra
					? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.thinMaterial))
			}
			.background {
				if let tint {
					shape.fill(tint.opacity(0.18))
				}
			}
			.overlay {
				shape.strokeBorder(
					LinearGradient(
						colors: [.white.opacity(0.28), .white.opacity(0.04)],
						startPoint: .top, endPoint: .bottom),
					lineWidth: 1)
			}
			.shadow(
				color: .black.opacity(prominent ? 0.18 : 0.10),
				radius: prominent ? 7 : 3, y: prominent ? 3 : 1)
	}
}

extension View {
	public func machmanGlass(
		cornerRadius: CGFloat, prominent: Bool = false, tint: Color? = nil
	) -> some View {
		modifier(MachmanGlassSurface(
			shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
			prominent: prominent, tint: tint))
	}

	public func machmanGlassCapsule(prominent: Bool = false, tint: Color? = nil) -> some View {
		modifier(MachmanGlassSurface(shape: Capsule(), prominent: prominent, tint: tint))
	}
}

// Standard interactive-hover treatment (macOS has no hoverEffect): overlay tint + optional
// slight scale, using the MachmanColors overlay strengths.
public struct MachmanHoverable: ViewModifier {
	@State private var hovering = false
	private let radius: CGFloat
	private let scales: Bool

	public init(radius: CGFloat = 5, scales: Bool = false) {
		self.radius = radius
		self.scales = scales
	}

	public func body(content: Content) -> some View {
		content
			.background(
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.fill(Color.primary.opacity(hovering ? MachmanColors.hoverOverlay : 0)))
			.scaleEffect(scales && hovering ? 1.04 : 1)
			.animation(.easeOut(duration: 0.12), value: hovering)
			.onHover { hovering = $0 }
	}
}

extension View {
	public func machmanHoverable(radius: CGFloat = 5, scales: Bool = false) -> some View {
		modifier(MachmanHoverable(radius: radius, scales: scales))
	}
}
