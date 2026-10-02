//
//  ActivityButton.swift
//  MachmanDesktopUI
//
//  The toolbar's activity list (PR5, decision 13): a native toolbar button, badged with the
//  warnings and failures nobody has looked at yet, opening a popover of the 50 newest
//  entries, newest first — finished operations, engine warnings, the desktop's problem
//  toasts. Each entry clears with its ✕, all of them with Clear All; opening the list marks
//  everything seen. It is there with or without a selected VM.
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

struct ActivityButton: View {
	@ObservedObject var activity: ActivityLog
	@State private var shown: Bool

	// `shown` opens the popover from the start (render scenes).
	init(activity: ActivityLog, shown: Bool = false) {
		self.activity = activity
		_shown = State(initialValue: shown)
	}

	var body: some View {
		Button {
			shown.toggle()
		} label: {
			Image(systemName: MachmanSymbols.activity)
				.overlay(alignment: .topTrailing) {
					if activity.unseenProblems > 0 {
						ActivityBadge(count: activity.unseenProblems)
							.offset(x: 7, y: -6)
					}
				}
		}
		.help(tooltip)
		.accessibilityLabel(tooltip)
		.popover(isPresented: $shown, arrowEdge: .bottom) {
			ActivityPopover(activity: activity)
		}
		// Opened, the list is read; closed, whatever arrived while it showed was seen too.
		.onChange(of: shown) { activity.markSeen() }
	}

	private var tooltip: String {
		let count = activity.unseenProblems
		return count == 0 ? "Activity" : "Activity — \(count) new problem\(count == 1 ? "" : "s")"
	}
}

struct ActivityBadge: View {
	let count: Int

	var body: some View {
		Text(count > 9 ? "9+" : "\(count)")
			.font(.system(size: 9, weight: .bold))
			.monospacedDigit()
			.foregroundStyle(.white)
			.padding(.horizontal, 4)
			.frame(minWidth: 14, minHeight: 14)
			.background(Capsule().fill(MachmanColors.stateError))
	}
}

struct ActivityPopover: View {
	@ObservedObject var activity: ActivityLog

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text("Activity")
					.font(.system(size: 12, weight: .semibold))
				Spacer()
				Button("Clear All") { activity.clearAll() }
					.buttonStyle(.borderless)
					.controlSize(.small)
					.disabled(activity.entries.isEmpty)
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			Divider()
			if activity.entries.isEmpty {
				Text("Finished operations and warnings show up here.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.padding(16)
					.frame(maxWidth: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 1) {
						ForEach(activity.entries) { entry in
							ActivityRow(entry: entry) { activity.dismiss(id: entry.id) }
						}
					}
					.padding(4)
				}
				.frame(maxHeight: 420)
			}
		}
		.frame(width: 340)
	}
}

struct ActivityRow: View {
	let entry: ActivityEntry
	let remove: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: entry.symbol)
				.font(.system(size: 12))
				.foregroundStyle(tint)
				.frame(width: 16)
			VStack(alignment: .leading, spacing: 2) {
				Text(entry.title)
					.font(.system(size: 12, weight: .medium))
					.lineLimit(2)
					.help(entry.title)
				if let detail = entry.detail {
					Text(detail)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(8)
						.textSelection(.enabled)
						.help(detail)
				}
				Text(time)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			IconButton(
				symbol: MachmanSymbols.closeTab, tooltip: "Remove", font: .caption, flat: true,
				action: remove)
				.opacity(hovering ? 1 : 0.35)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: 6)
			.fill(Color.primary.opacity(hovering ? MachmanColors.hoverOverlay : 0)))
		.onHover { hovering = $0 }
	}

	// Today's entries by time; older ones with their date too (the list outlives a day).
	private var time: String {
		Calendar.current.isDateInToday(entry.date)
			? entry.date.formatted(date: .omitted, time: .shortened)
			: entry.date.formatted(date: .abbreviated, time: .shortened)
	}

	private var tint: AnyShapeStyle {
		switch entry.severity {
		case .failure: return AnyShapeStyle(MachmanColors.stateError)
		case .warning: return AnyShapeStyle(MachmanColors.warning)
		case .done: return AnyShapeStyle(MachmanColors.stateRunning)
		case .info: return AnyShapeStyle(.secondary)
		}
	}
}
