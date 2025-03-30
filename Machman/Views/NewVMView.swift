//
//  NewVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-30.
//

import SwiftUI
import Foundation

enum NewVMStatus {
	case none
	case good
	case error(String)
	case warning(String)
	case inform(String)
}

struct NewVMView: View {
	var viewModel = VMListViewModel()
	let defFontSize: CGFloat = 20
	@State private var vmName: String = ""
	@State private var vmMemory: UInt64 = 0
	@State private var vmCpuCount: Int = 1
	@State private var vmDiskSize: UInt64 = 0
	@State private var vmDiskSizeStringGB: String = ""
	@State private var vmMemoryGBString: String = ""
	@State private var newVmStatus: NewVMStatus = .none
	@State private var bounce = false
	@Environment(\.dismiss) private var dismiss

	init(viewModel: VMListViewModel) {
		self.viewModel = viewModel
	}

	static func getAvailableVMDiskSpace() -> Int? {
		let homeURL = URL(fileURLWithPath: machmanVMDir)

		do {
			let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
			if let available = values.volumeAvailableCapacityForImportantUsage {
				return VMConfig.toGB(size: UInt64(available)) // in bytes
			}
			return nil
		} catch {
			return nil
		}
	}
	func checkForErrors(_ chackName: Bool) -> Bool {
		if chackName && viewModel.hasVM(vmName) {
			newVmStatus = .error("A VM named '\(vmName)' already exists.")
			vmName = ""
			return true
		}
		guard !vmName.isEmpty else {
			switch newVmStatus {
			case .error(_:):
				return true
			default:
				self.newVmStatus = .none
				return false
			}
		}
		if (vmMemory == 0 || vmCpuCount == 0 || vmDiskSize == 0) {
			self.newVmStatus = .none
			return false
		}
		self.newVmStatus = .good
		return false
	}
	func isReady() -> Bool {
		switch newVmStatus {
		case .good:
			return true
		default:
			return false
		}
	}
	func createVM() -> Bool{
		guard !vmName.isEmpty else {
			newVmStatus = .error("Please enter a valid name")
			return false
		}
		if viewModel.hasVM(vmName) {
			newVmStatus = .error("A VM named '\(vmName)' already exists.")
			return false
		}
		if (vmMemory == 0 || vmCpuCount == 0 || vmDiskSize == 0) {
			newVmStatus = .error("Uninitialized parameters. Please check all fields.")
			return false
		}
		do {
			try VMConfig.createNewVMDirectory(name: vmName)
		} catch {
			newVmStatus = .error("Failed to initialize directory for VM '\(vmName)': \(error.localizedDescription).")
			return false
		}
		if let newVM = try? VMConfig(name: vmName, memorySize: vmMemory, cpuCount: vmCpuCount, diskSize: vmDiskSize) {
			viewModel.addVM(vmConfig: newVM)
			return true
		} else {
			newVmStatus = .error("Failed to initialize VMConfig for VM '\(vmName)'")
			return false
		}
	}
	var body: some View {
		NavigationStack{
			VStack {

				Text("Create new VM")
					.font(.system(size: 35, weight: .medium, design: .default))

				VStack(alignment: .leading, spacing: 16) {
					TextField("VM Name", text: $vmName)
						.textFieldStyle(.roundedBorder)
						.onSubmit {
							_ = checkForErrors(true)
						}
						.font(.system(size: defFontSize, weight: .medium, design: .default))
						.frame(maxWidth: 400)
					HStack {
						Image(systemName: "cpu.fill")
							.font(.system(size: defFontSize, weight: .medium, design: .default))
						Stepper("CPU Count: \(vmCpuCount)", value: $vmCpuCount, in: 1...VMConfig.computeMaxCPUCount())
							.font(.system(size: defFontSize, weight: .medium, design: .default))
						Spacer()
					}.frame(maxWidth: 400)
					HStack {
						Image(systemName: "memorychip.fill")
							.font(.system(size: defFontSize, weight: .medium, design: .default))
						TextField("Memory (GB)", text: $vmMemoryGBString)
							.font(.system(size: defFontSize, weight: .medium, design: .default))
							.textFieldStyle(.roundedBorder)
							.onReceive(vmMemoryGBString.publisher.collect()) { chars in
								DispatchQueue.main.async {
									vmMemoryGBString = String(chars.prefix(4).filter { "0123456789".contains($0) })
									vmMemory = VMConfig.clampMemorySize(size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0))
									_ = checkForErrors(false)
								}
							}.onSubmit {
								DispatchQueue.main.async {
									vmMemory = VMConfig.clampMemorySize(size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0))
									vmMemoryGBString = "\(VMConfig.toGB(size: vmMemory))"
									_ = checkForErrors(false)
								}
							}
					}.frame(maxWidth: 400)
					HStack {
						Image(systemName: "internaldrive.fill")
							.font(.system(size: defFontSize, weight: .medium, design: .default))
						TextField("Disk Size (GB)", text: $vmDiskSizeStringGB)
							.font(.system(size: defFontSize, weight: .medium, design: .default))
							.textFieldStyle(.roundedBorder)
							.frame(width: 100)
							.onReceive(vmDiskSizeStringGB.publisher.collect()) { chars in
								DispatchQueue.main.async {
									vmDiskSizeStringGB = String(chars.prefix(4).filter { "0123456789".contains($0) })
									vmDiskSize = VMConfig.fromGB(size: min(
										Int(vmDiskSizeStringGB) ?? 0,
										NewVMView.getAvailableVMDiskSpace() ?? Int.max
									))
									_ = checkForErrors(false)
								}

							}.onSubmit {
								DispatchQueue.main.async {
									vmDiskSize = VMConfig.fromGB(size: min(
										Int(vmDiskSizeStringGB) ?? 0,
										NewVMView.getAvailableVMDiskSpace() ?? Int.max
									))
									vmDiskSizeStringGB = "\(VMConfig.toGB(size: vmDiskSize))"
									_ = checkForErrors(false)
								}
							}
						Text("Available: \(NewVMView.getAvailableVMDiskSpace()?.formatted() ?? "?") GB")
							.font(.system(size: defFontSize, weight: .medium, design: .default))
						Spacer()
					}.frame(maxWidth: 400)
					HStack {
						Button {
							if createVM() {
								dismiss()
							}
						} label: {
							Image(systemName: "plus")
								.font(.system(size: defFontSize + 10, weight: .medium, design: .default))
						}.buttonStyle(.borderless)
						.contentShape(Rectangle())
						.help("create new virtual machine")
						.font(.system(size: defFontSize, weight: .medium, design: .default))
						.disabled(!isReady()) // 👈 control enabled state
						.opacity(isReady() ? 1.0 : 0.5) // 👈 visual feedback
						.onHover { hovering in
							if (hovering && isReady()) { NSCursor.pointingHand.push() } else { NSCursor.pop() }
						}

						Group {
							switch newVmStatus {
							case .none:
								EmptyView()
							case .good:
								Image(systemName: "checkmark")
									.foregroundColor(.green)
									.font(.system(size: defFontSize, weight: .medium, design: .default))
							case .error(let string):
								HStack(spacing: 4) {
									Image(systemName: "exclamationmark.triangle.fill")
										.foregroundColor(.red)
										.scaleEffect(bounce ? 1.2 : 1.0)
										.animation(.interpolatingSpring(stiffness: 300, damping: 5), value: bounce)
										.font(.system(size: defFontSize, weight: .medium, design: .default))
										.contentShape(Rectangle())
										.help(string) // Tooltip on hover
										.onAppear {
											NSSound(named: NSSound.Name("Submarine"))?.play()
											bounce = true
										}
									Text(string)
										.lineLimit(1)
										.truncationMode(.tail)
										.font(.system(size: defFontSize - 4, weight: .medium, design: .default))
								}
							case .inform(_):
								EmptyView()
							case .warning(let string):
								HStack(spacing: 4) {
									Image(systemName: "exclamationmark.triangle.fill")
										.foregroundColor(.yellow)
										.scaleEffect(bounce ? 1.2 : 1.0)
										.animation(.interpolatingSpring(stiffness: 300, damping: 5), value: bounce)
										.font(.system(size: 15, weight: .medium, design: .default))
										.font(.system(size: defFontSize, weight: .medium, design: .default))
										.contentShape(Rectangle())
										.help(string) // Tooltip on hover
										.onAppear {
											bounce = true
										}
									Text(string)
										.lineLimit(1)
										.truncationMode(.tail)
										.font(.system(size: defFontSize - 4, weight: .medium, design: .default))
								}
							}
						}
					}
				}
				.padding()
				.frame(maxWidth: 1000)
			}
		}
	}
}

#Preview {
}
