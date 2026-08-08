//
//  HardwareConfigView.swift
//  Machman
//
//  CPU / memory configuration block, extracted from ConfigVMView. Bounds come from
//  HostCapabilities (via the view model) — never from Virtualization.framework directly.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct HardwareConfigView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	@State private var vmMemory: UInt64
	@State private var vmCpuCount: Int
	@State private var vmMemoryString: String

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_vmMemory = State(initialValue: vm.memoryBytes)
		_vmCpuCount = State(initialValue: vm.cpuCount)
		_vmMemoryString = State(initialValue: ByteSize.format(vm.memoryBytes))
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
				Image(systemName: MachmanSymbols.cpu)
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
				Image(systemName: MachmanSymbols.network)
					.fontWeight(.bold)
					.font(.title2)
					.help("MAC address (assigned on first boot)")
			}
			.padding(2)
			HStack {
				EditableText($vmMemoryString)
					.fontWeight(.bold)
					.font(.title2)
					.onReceive(vmMemoryString.publisher.collect()) { chars in
						DispatchQueue.main.async {
							// Permissive while typing; all interpretation happens on submit.
							vmMemoryString = String(
								chars.prefix(12).filter { "0123456789.,kmgbKMGB ".contains($0) })
						}
					}.onSubmit {
						DispatchQueue.main.async {
							// Bare number = bytes; k/m/g[b] = binary units; decimals accepted.
							// Unparseable reverts; out-of-range lands on min/max via the clamp.
							guard let parsed = ByteSize.parse(vmMemoryString) else {
								vmMemoryString = ByteSize.format(vmMemory)
								return
							}
							vmMemory = viewModel.clampMemory(
								ByteSize.roundToMiB(parsed), floor: memoryFloor)
							vmMemoryString = ByteSize.format(vmMemory)
							viewModel.setHardware(vm.name, memoryBytes: vmMemory)
						}
					}
					.help("\(vmMemory.formatted()) bytes")
				Image(systemName: MachmanSymbols.memory)
					.fontWeight(.bold)
					.font(.title2)
				Text("RAM")
					.fontWeight(.bold)
					.font(.title2)
				Spacer()
				Text(vm.macAddress ?? "—")
					.font(.system(.title3, design: .monospaced))
					.foregroundColor(vm.macAddress == nil ? .secondary : .primary)
					.help("MAC address (assigned on first boot)")
				if let mac = vm.macAddress {
					CopyToClipboardButton(mac, tooltip: "Copy MAC address")
				}
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
				vmMemoryString = ByteSize.format(vmMemory)
				viewModel.setHardware(vm.name, memoryBytes: vmMemory)
			}
		}
	}
}

#Preview {
}
