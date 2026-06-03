//
//  HardwareConfigView.swift
//  Machman
//
//  CPU / memory configuration block, extracted from ConfigVMView.
//

import SwiftUI

struct HardwareConfigView: View {
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

	// macOS guests carry install-time hardware minimums; other modes have none.
	private var hardwareFloors: (cpu: Int, mem: UInt64)? { vm.config.boot.hardwareFloors }

	private var cpuRange: ClosedRange<Int> {
		let lower = max(1, hardwareFloors?.cpu ?? 1)
		let upper = max(VMConfig.computeMaxCPUCount(), lower)
		return lower...upper
	}

	private var memoryFloor: UInt64 { hardwareFloors?.mem ?? 0 }

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
							vmMemoryGBString = String(chars.prefix(4).filter { "0123456789".contains($0) })
							vmMemory = VMConfig.clampMemorySize(
								size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0), floor: memoryFloor)
						}
					}.onSubmit {
						DispatchQueue.main.async {
							vmMemory = VMConfig.clampMemorySize(
								size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0), floor: memoryFloor)
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
				Text(vm.config.macAddress ?? "—")
					.font(.system(.title3, design: .monospaced))
					.foregroundColor(vm.config.macAddress == nil ? .secondary : .primary)
					.help("MAC address (assigned on first boot)")
			}
			.padding(2)
		}
		.padding(2)
		.onAppear {
			guard let floors = hardwareFloors else { return }
			if vmCpuCount < floors.cpu {
				vmCpuCount = floors.cpu   // Stepper onChange persists via setCPUCount
			}
			if vmMemory < floors.mem {
				vmMemory = VMConfig.clampMemorySize(size: floors.mem, floor: floors.mem)
				vmMemoryGBString = "\(VMConfig.toGB(size: vmMemory))"
				try? vm.config.setMemorySize(vmMemory)
			}
		}
	}
}

#Preview {
}
