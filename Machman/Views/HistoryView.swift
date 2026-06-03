//
//  HistoryView.swift
//  Machman
//
//  Run-state / last-use / created block, extracted from ConfigVMView.
//

import SwiftUI

struct HistoryView: View {
	@State private var vm: VirtualMachine

	init(vm: VirtualMachine) {
		self.vm = vm
	}

	func largestTimeDifference(from date: Date) -> String {
		let now = Date()
		let diff = now.timeIntervalSince(date)

		// Define time interval constants
		let second: TimeInterval = 1
		let minute = 60 * second
		let hour   = 60 * minute
		let day    = 24 * hour
		let week   = 7 * day
		let month  = 30.44 * day  // average month length
		let year   = 365.25 * day // average year length

		if diff < minute {
			// Less than a minute: show seconds
			let seconds = Int(diff)
			return "\(seconds)s"
		} else if diff < hour {
			// Less than an hour: show minutes
			let minutes = Int(diff / minute)
			return "\(minutes)m"
		} else if diff < day {
			// Less than a day: show hours
			let hours = Int(diff / hour)
			return "\(hours)h"
		} else if diff < week {
			// Less than a week: show days
			let days = Int(diff / day)
			return "\(days)day"
		} else if diff < month {
			// Less than a month: show weeks
			let weeks = Int(diff / week)
			return "\(weeks)wk"
		} else if diff < year {
			// Less than a year: show months
			let months = Int(diff / month)
			return "\(months)mo"
		} else {
			// One year or more: show years
			let years = Int(diff / year)
			return "\(years)y"
		}
	}

	var body: some View {
		GroupBox {
			HStack {
				if let startTime = vm.config.lastRan {
					if vm.config.state == .running {
						Text(largestTimeDifference(from: startTime))
							.fontWeight(.bold)
							.font(.title2)
					} else {
						Text("stopped")
							.fontWeight(.bold)
							.font(.title2)
					}
				} else {
					Text("stopped")
						.fontWeight(.bold)
						.font(.title2)
				}
				Spacer()
			}
			.padding(2)
			if let lastUse = vm.config.lastRan {
				HStack {
					Text("last use:")
						.fontWeight(.bold)
						.font(.title2)
					Text("\(lastUse)")
					Spacer()
				}
				.padding(2)
			}
			HStack {
				Text("created:")
					//.padding(.trailing, 2)
					.fontWeight(.bold)
					.font(.title2)
				Text("\(vm.config.created)")
				Spacer()

			}
			.padding(2)
		}
		.padding(2)
	}
}

#Preview {
}
