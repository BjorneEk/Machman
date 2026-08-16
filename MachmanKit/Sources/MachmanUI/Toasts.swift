//
//  Toasts.swift
//  MachmanUI
//
//  Bottom-right passive feedback (1.0.4 UI): transient toasts for confirmations/warnings
//  and persistent progress cards for long-running operations (step text, determinate bar,
//  live ETA, cancel ×). The HIG feedback pattern: passive status near the corner beats
//  interrupting dialogs; a small indicator stays near the control that started the work
//  while the detailed card lives here.
//

import SwiftUI

public struct MachmanToast: Identifiable, Equatable {
	public let id = UUID()
	public var symbol: String
	public var message: String
	public var tint: Color?
	// A named slot rather than one more toast in the pile: pushing the same key replaces
	// what is showing (waiting → ready), which is how a state that MOVES is reported
	// without stacking three toasts for one event.
	public var key: String?
	// Waiting on something whose end we will hear about: a spinner instead of a symbol,
	// and no timer — the toast lives until its key is replaced or dismissed.
	public var spinner: Bool
	public var sticky: Bool

	public init(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		self.symbol = symbol
		self.message = message
		self.tint = tint
		self.key = key
		self.spinner = spinner
		self.sticky = sticky
	}
}

// A progress card's display model — mapped from OperationInfo / InstallPhase by the app
// (ETA is consumer math, computed there).
public struct ProgressCardModel: Identifiable, Equatable {
	public var id: String
	public var title: String
	public var symbol: String
	public var phase: String
	public var fraction: Double?             // nil = indeterminate
	public var etaSeconds: Double?

	public init(
		id: String, title: String, symbol: String, phase: String,
		fraction: Double? = nil, etaSeconds: Double? = nil
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.phase = phase
		self.fraction = fraction
		self.etaSeconds = etaSeconds
	}
}

public struct ToastStack: View {
	private let toasts: [MachmanToast]
	private let progress: [ProgressCardModel]
	private let dismissProgress: (String) -> Void

	public init(
		toasts: [MachmanToast], progress: [ProgressCardModel] = [],
		dismissProgress: @escaping (String) -> Void = { _ in }
	) {
		self.toasts = toasts
		self.progress = progress
		self.dismissProgress = dismissProgress
	}

	public var body: some View {
		VStack(alignment: .trailing, spacing: 6) {
			ForEach(toasts) { toast in
				HStack(spacing: 6) {
					if toast.spinner {
						ProgressView()
							.controlSize(.small)
							.scaleEffect(0.7)
							.frame(width: 14, height: 14)
					} else {
						Image(systemName: toast.symbol)
							.foregroundStyle(toast.tint.map(AnyShapeStyle.init)
								?? AnyShapeStyle(.secondary))
					}
					Text(toast.message).font(.callout)
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.machmanGlassCapsule()
				.allowsHitTesting(false)
				.transition(.move(edge: .bottom).combined(with: .opacity))
			}
			ForEach(progress) { card in
				ProgressCard(card: card) { dismissProgress(card.id) }
					.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.spring(duration: 0.35), value: toasts)
		.animation(.spring(duration: 0.35), value: progress)
	}
}

public struct ProgressCard: View {
	private let card: ProgressCardModel
	private let dismiss: () -> Void
	@State private var hoveringClose = false

	public init(card: ProgressCardModel, dismiss: @escaping () -> Void) {
		self.card = card
		self.dismiss = dismiss
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: card.symbol)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
				Text(card.title)
					.font(.system(size: 12, weight: .medium))
					.lineLimit(1)
				Spacer(minLength: 8)
				Button(action: dismiss) {
					Image(systemName: MachmanSymbols.closeTab)
						.font(.system(size: 8, weight: .bold))
						.frame(width: 14, height: 14)
						.background(Circle()
							.fill(Color.primary.opacity(hoveringClose ? 0.18 : 0.08)))
				}
				.buttonStyle(.plain)
				.onHover { hoveringClose = $0 }
				.help("Cancel")
			}
			if let value = card.fraction {
				ProgressView(value: value)
					.controlSize(.small)
			} else {
				ProgressView()
					.controlSize(.small)
			}
			HStack {
				Text(card.phase)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Spacer(minLength: 8)
				if let eta = card.etaSeconds, eta > 0.5 {
					Text(Self.etaString(eta))
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.monospacedDigit()
				}
			}
		}
		.padding(10)
		.frame(width: 280)
		.machmanGlass(cornerRadius: 10, prominent: true)
	}

	private static func etaString(_ seconds: Double) -> String {
		let formatted = Duration.seconds(seconds).formatted(
			.units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 2))
		return "about \(formatted) left"
	}
}
