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

	var body: some View {
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
}

#Preview {
}
