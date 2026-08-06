//
//  HardwareConfigView.swift
//  Machman
//
//  CPU / memory configuration block, extracted from ConfigVMView. Bounds come from
//  HostCapabilities (via the view model) — never from Virtualization.framework directly.
//

import SwiftUI
import MachmanAPI

struct HardwareConfigView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	@State private var vmMemory: UInt64
	@State private var vmCpuCount: Int
	@State private var vmMemoryGBString: String

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_vmMemory = State(initialValue: vm.memoryBytes)
		_vmCpuCount = State(initialValue: vm.cpuCount)
		_vmMemoryGBString = State(initialValue: ByteSize.toGB(vm.memoryBytes).formatted())
	}

	// macOS guests carry install-time hardware minimums; other modes have none.
	private var cpuFloor: Int { max(1, vm.boot.minCPUCount ?? 1) }
	private var memoryFloor: UInt64 { vm.boot.minMemoryBytes ?? 0 }

	private var cpuRange: ClosedRange<Int> {
		let upper = max(viewModel.capabilities?.maxCPUCount ?? cpuFloor, cpuFloor)
		return cpuFloor...upper
	}

	var body: some View {
		GroupBox {
			HStack {
				Text("\(vmCpuCount)")
					.fontWeight(.bold)
					.font(.title2)
				Image(systemName: "cpu.fill")
					.fontWeight(.bold)
					.font(.title2)
				Stepper("CPUs", value: $vmCpuCount, in: cpuRange)
					.fontWeight(.bold)
					.font(.title2)
					.onChange(of: vmCpuCount) { _, newValue in
						DispatchQueue.main.async {
							viewModel.setHardware(vm.name, cpuCount: newValue)
						}
					}
				Spacer()
				Image(systemName: "network")
					.fontWeight(.bold)
					.font(.title2)
					.help("MAC address (assigned on first boot)")
			}
			.padding(2)
			HStack {
				EditableText($vmMemoryGBString)
					.fontWeight(.bold)
					.font(.title2)
					.onReceive(vmMemoryGBString.publisher.collect()) { chars in
						DispatchQueue.main.async {
							vmMemoryGBString = String(
								chars.prefix(4).filter { "0123456789".contains($0) })
							vmMemory = viewModel.clampMemory(
								ByteSize.fromGB(Int(vmMemoryGBString) ?? 0), floor: memoryFloor)
						}
					}.onSubmit {
						DispatchQueue.main.async {
							vmMemory = viewModel.clampMemory(
								ByteSize.fromGB(Int(vmMemoryGBString) ?? 0), floor: memoryFloor)
							vmMemoryGBString = "\(ByteSize.toGB(vmMemory))"
							viewModel.setHardware(vm.name, memoryBytes: vmMemory)
						}
					}
				Image(systemName: "memorychip.fill")
					.fontWeight(.bold)
					.font(.title2)
				Text("GB RAM")
					.fontWeight(.bold)
					.font(.title2)
				Spacer()
				Text(vm.macAddress ?? "—")
					.font(.system(.title3, design: .monospaced))
					.foregroundColor(vm.macAddress == nil ? .secondary : .primary)
					.help("MAC address (assigned on first boot)")
			}
			.padding(2)
		}
		.padding(2)
		.onAppear {
			if vmCpuCount < cpuFloor {
				vmCpuCount = cpuFloor   // Stepper onChange persists via setHardware
			}
			if vmMemory < memoryFloor {
				vmMemory = viewModel.clampMemory(memoryFloor, floor: memoryFloor)
				vmMemoryGBString = "\(ByteSize.toGB(vmMemory))"
				viewModel.setHardware(vm.name, memoryBytes: vmMemory)
			}
		}
	}
}

#Preview {
}
