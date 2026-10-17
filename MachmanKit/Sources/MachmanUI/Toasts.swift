//
//  Toasts.swift
//  MachmanUI
//
//  Bottom-right passive feedback (1.0.4 UI): transient toasts for confirmations/warnings
//  and persistent progress cards for long-running operations (step text, determinate bar,
//  live ETA, and a × that cancels a running operation — absent while the engine can't
//  cancel it — and dismisses a finished one). The
//  HIG feedback pattern: passive status near the corner beats interrupting dialogs; a small
//  indicator stays near the control that started the work while the detailed card lives
//  here. What lands here is also said to VoiceOver as it arrives (H56): a transient toast is
//  gone before anyone could navigate to it.
//

import SwiftUI

public struct MachmanToast: Identifiable, Equatable {
	// Fresh per toast, unless a status toast that is recomputed per render passes its own
	// fixed id, so it doesn't re-animate every time.
	public let id: UUID
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
		id: UUID = UUID(), symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		self.id = id
		self.symbol = symbol
		self.message = message
		self.tint = tint
		self.key = key
		self.spinner = spinner
		self.sticky = sticky
	}
}

extension MachmanToast {
	// A problem worth interrupting for: every problem toast (pushProblem, engine warnings,
	// the stale list) carries the warning tint, and only problems do.
	public var isProblem: Bool {
		tint == MachmanColors.warning || tint == MachmanColors.problem
			|| tint == MachmanColors.stateError
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
	// Showing its outcome: the × only dismisses the card (nothing left to cancel).
	public var finished: Bool
	// Running work the engine can't stop shows no × until it finishes (F7).
	public var cancellable: Bool

	public init(
		id: String, title: String, symbol: String, phase: String,
		fraction: Double? = nil, etaSeconds: Double? = nil, finished: Bool = false,
		cancellable: Bool = true
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.phase = phase
		self.fraction = fraction
		self.etaSeconds = etaSeconds
		self.finished = finished
		self.cancellable = cancellable
	}

	// What the bar shows: the fraction; once finished without one (a failure, a cancel
	// before any progress), an empty bar that holds still; nil spins (still working).
	public var barValue: Double? {
		fraction ?? (finished ? 0 : nil)
	}
}

public struct ToastStack: View {
	// A toast's text wraps at this width (up to four lines) instead of running across the
	// window; the tooltip and the activity list keep the whole text (F6).
	static let maxToastWidth: CGFloat = 340

	private let toasts: [MachmanToast]
	private let progress: [ProgressCardModel]
	private let dismissProgress: (String) -> Void
	private let hoverToast: (UUID, Bool) -> Void
	@Environment(\.toastAnnouncer) private var announcer

	public init(
		toasts: [MachmanToast], progress: [ProgressCardModel] = [],
		dismissProgress: @escaping (String) -> Void = { _ in },
		hoverToast: @escaping (UUID, Bool) -> Void = { _, _ in }
	) {
		self.toasts = toasts
		self.progress = progress
		self.dismissProgress = dismissProgress
		self.hoverToast = hoverToast
	}

	public var body: some View {
		VStack(alignment: .trailing, spacing: 6) {
			ForEach(toasts) { toast in
				HStack(spacing: 6) {
					if toast.spinner {
						ProgressView()
							.controlSize(.small)
					} else {
						Image(systemName: toast.symbol)
							.foregroundStyle(toast.tint.map(AnyShapeStyle.init)
								?? AnyShapeStyle(.secondary))
					}
					CappedWidth(max: Self.maxToastWidth) {
						Text(toast.message)
							.font(.callout)
							.lineLimit(4)
					}
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				// A one-line toast still reads as a capsule; a wrapped one as a rounded card.
				.machmanGlass(cornerRadius: 15)
				.help(toast.message)
				// Hit-testable so the pointer can hold it: the owner keeps a hovered toast.
				.onHover { hoverToast(toast.id, $0) }
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
		.onChange(of: toasts) { old, new in
			for announcement in Self.announcements(from: old, to: new) {
				announcer.post(announcement)
			}
		}
		.onChange(of: progress) { old, new in
			for announcement in Self.announcements(from: old, to: new) {
				announcer.post(announcement)
			}
		}
	}

	// The toasts that arrived: each new one once, except a keyed slot replaced with the same
	// words (a wait re-pushed says nothing new). A toast leaving says nothing.
	public static func announcements(
		from old: [MachmanToast], to new: [MachmanToast]
	) -> [ToastAnnouncement] {
		let shown = Set(old.map(\.id))
		let slots = Dictionary(
			old.compactMap { toast in toast.key.map { ($0, toast.message) } },
			uniquingKeysWith: { first, _ in first })
		return new
			.filter { !shown.contains($0.id) }
			.filter { toast in toast.key.map { slots[$0] != toast.message } ?? true }
			.map { ToastAnnouncement(text: $0.message, urgent: $0.isProblem) }
	}

	// The cards that finished (or arrived finished): the outcome, once. Running work is
	// shown, not said.
	public static func announcements(
		from old: [ProgressCardModel], to new: [ProgressCardModel]
	) -> [ToastAnnouncement] {
		let finished = Set(old.filter(\.finished).map(\.id))
		return new
			.filter { $0.finished && !finished.contains($0.id) }
			.map { ToastAnnouncement(text: "\($0.title): \($0.phase)", urgent: false) }
	}
}

// One thing the corner says to VoiceOver; an urgent one interrupts what it is saying.
public struct ToastAnnouncement: Equatable, Sendable {
	public let text: String
	public let urgent: Bool

	public init(text: String, urgent: Bool) {
		self.text = text
		self.urgent = urgent
	}
}

// Who hears the corner: VoiceOver, through the system's announcement, or a test's recorder.
public struct ToastAnnouncer: Sendable {
	public let post: @MainActor @Sendable (ToastAnnouncement) -> Void

	public init(post: @escaping @MainActor @Sendable (ToastAnnouncement) -> Void) {
		self.post = post
	}

	public static let voiceOver = ToastAnnouncer { announcement in
		AccessibilityNotification.Announcement(speech(for: announcement)).post()
	}

	// What VoiceOver is handed (H56, review F17): a routine announcement queued behind the current
	// speech, so a burst keeps every one; a problem interrupts. (.default would interrupt
	// and be cut off by the next post.)
	public static func speech(for announcement: ToastAnnouncement) -> AttributedString {
		var text = AttributedString(announcement.text)
		text.accessibilitySpeechAnnouncementPriority = announcement.urgent ? .high : .low
		return text
	}
}

private struct ToastAnnouncerKey: EnvironmentKey {
	static let defaultValue = ToastAnnouncer.voiceOver
}

extension EnvironmentValues {
	public var toastAnnouncer: ToastAnnouncer {
		get { self[ToastAnnouncerKey.self] }
		set { self[ToastAnnouncerKey.self] = newValue }
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
					.help(card.title)
				Spacer(minLength: 8)
				if card.finished || card.cancellable {
					Button(action: dismiss) {
						Image(systemName: MachmanSymbols.closeTab)
							.font(.system(size: 8, weight: .bold))
							.frame(width: 14, height: 14)
							.background(Circle()
								.fill(Color.primary.opacity(hoveringClose ? 0.18 : 0.08)))
					}
					.buttonStyle(.plain)
					.onHover { hoveringClose = $0 }
					.help(card.finished ? "Dismiss" : "Cancel")
					.accessibilityLabel(card.finished ? "Dismiss" : "Cancel")
				}
			}
			if let value = card.barValue {
				ProgressView(value: value)
					.controlSize(.small)
			} else {
				ProgressView()
					.controlSize(.small)
			}
			HStack {
				// A finished card's phase is its outcome, often a failure's sentence: it wraps
				// (L4); the activity list keeps the whole text.
				Text(card.phase)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(card.finished ? 3 : 1)
					.fixedSize(horizontal: false, vertical: true)
					.help(card.phase)
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

// Its one child at its ideal width, but never wider than `max`: a short line stays snug, a
// long one wraps at `max` and grows in height. (frame(maxWidth:) stretches the short one to
// the cap, and adding fixedSize clips the long one to a single line.)
struct CappedWidth: Layout {
	let max: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard let child = subviews.first else { return .zero }
		let limit = Swift.min(proposal.width ?? max, max)
		let ideal = child.sizeThatFits(.unspecified)
		return child.sizeThatFits(
			ProposedViewSize(width: Swift.min(ideal.width, limit), height: nil))
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		subviews.first?.place(
			at: bounds.origin,
			proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
	}
}
