//
//  HistoryView.swift
//  Machman
//
//  Uptime, total runtime, last use, and creation date as a fixed icon grid: every row is
//  always present ("—" when there is nothing to show) so the box never changes size, and the
//  tooltips carry the meaning instead of text labels.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct HistoryView: View {
	let vm: VMInfo

	// Single-unit compact duration ("3h", "2wk"), shared by uptime and total runtime.
	private func durationString(_ diff: TimeInterval) -> String {
		let minute = 60.0
		let hour = 60 * minute
		let day = 24 * hour
		let week = 7 * day
		let month = 30.44 * day  // average month length
		let year = 365.25 * day  // average year length
		switch diff {
		case ..<minute: return "\(Int(diff))s"
		case ..<hour: return "\(Int(diff / minute))m"
		case ..<day: return "\(Int(diff / hour))h"
		case ..<week: return "\(Int(diff / day))day"
		case ..<month: return "\(Int(diff / week))wk"
		case ..<year: return "\(Int(diff / month))mo"
		default: return "\(Int(diff / year))y"
		}
	}

	private var uptime: String? {
		guard vm.state.isRunning, let lastRan = vm.lastRan else { return nil }
		return durationString(Date().timeIntervalSince(lastRan))
	}

	private var totalRuntime: String? {
		guard let total = vm.totalRuntimeSeconds, total > 0 else { return nil }
		return durationString(total)
	}

	var body: some View {
		GroupBox {
			Grid(alignment: .leading, verticalSpacing: 6) {
				GridRow {
					cell(MachmanSymbols.uptime, "Current uptime", uptime)
					cell(MachmanSymbols.totalRuntime, "Total runtime", totalRuntime)
				}
				GridRow {
					cell(
						MachmanSymbols.lastUsed, "Last used",
						vm.lastRan?.formatted(date: .abbreviated, time: .shortened))
						.gridCellColumns(2)
				}
				GridRow {
					cell(
						MachmanSymbols.created, "Created",
						vm.created.formatted(date: .abbreviated, time: .shortened))
						.gridCellColumns(2)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(2)
		}
		.padding(2)
	}

	private func cell(_ symbol: String, _ tooltip: String, _ value: String?) -> some View {
		HStack(spacing: 6) {
			Image(systemName: symbol)
				.foregroundColor(.secondary)
			Text(value ?? "—")
				.monospacedDigit()
		}
		.help(tooltip)
	}
}

#Preview {
}
