//
//  ConfigVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct ConfigVMView: View {
	@State private var vm: VirtualMachine

	@State private var vmMemory: UInt64
	@State private var vmCpuCount: Int
	@State private var vmMemoryGBString: String

	init(vm: VirtualMachine) {
		self.vm = vm
		vmMemory = vm.config.memorySize
		vmCpuCount = vm.config.cpuCount
		vmMemoryGBString = VMConfig.toGB(size: vm.config.memorySize).formatted()
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
			VStack {
				GroupBox {
					HStack {
						Text("\(vmCpuCount)")
							.fontWeight(.bold)
							.font(.title2)
						Image(systemName: "cpu.fill")
							.fontWeight(.bold)
							.font(.title2)
						Stepper("CPUs", value: $vmCpuCount, in: 1...VMConfig.computeMaxCPUCount())
							.fontWeight(.bold)
							.font(.title2)
							.onChange(of: vmCpuCount) { oldValue, newValue in
								DispatchQueue.main.async {
									do {
										try self.vm.config.setCPUCount(vmCpuCount)
										vm.log(message: "Set CPU count for \(self.vm.config.name) to \(vmCpuCount)")
									} catch {
										vm.log(error: "Failed to set CPU count for VM from \(oldValue) to \(newValue): \(error.localizedDescription)")
									}
								}
							}
						Spacer()
					}
					.padding(2)
					HStack {
						EditableText($vmMemoryGBString)
							.fontWeight(.bold)
							.font(.title2)
							.onReceive(vmMemoryGBString.publisher.collect()) { chars in
								DispatchQueue.main.async {
									vmMemoryGBString = String(chars.prefix(4).filter { "0123456789".contains($0) })
									vmMemory = VMConfig.clampMemorySize(size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0))
								}
							}.onSubmit {
								DispatchQueue.main.async {
									vmMemory = VMConfig.clampMemorySize(size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0))
									vmMemoryGBString = "\(VMConfig.toGB(size: vmMemory))"
									do {
										try self.vm.config.setMemorySize(vmMemory)
										vm.log(message: "Set memory size for \(self.vm.config.name) to \(vmMemoryGBString) GB")
									} catch {
										vm.log(error: "Failed to set memory size for VM: \(error.localizedDescription)")
									}
								}
							}
						Image(systemName: "memorychip.fill")
							.fontWeight(.bold)
							.font(.title2)
						Text("GB RAM")
							.fontWeight(.bold)
							.font(.title2)
						Spacer()
					}
					.padding(2)
				}
				.padding(2)
			}
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
			Spacer()
		}
	}
}

#Preview {
}
