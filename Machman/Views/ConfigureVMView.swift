//
//  ConfigureVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-30.
//

import SwiftUI

struct ConfigureVMView: View {
	var config: VMConfig
	var viewModel = VMListViewModel()
	let defFontSize: CGFloat = 20
	@State private var vmName: String = ""
	@State private var vmMemory: UInt64 = 0
	@State private var vmCpuCount: Int = 1
	@State private var vmMemoryGBString: String = ""
	@State private var newVmStatus: NewVMStatus = .none
	@State private var bounce = false

	@State private var newPath: String = ""
	@State private var newTag: String = ""
	@State private var refreshTrigger = 0

	init (viewModel: VMListViewModel, config: VMConfig) {
		self.config = config
		self.viewModel = viewModel
		self._vmName = State(initialValue: config.name)
		self._vmMemory = State(initialValue: config.memorySize)
		self._vmCpuCount = State(initialValue: config.cpuCount)
		self._vmMemoryGBString = State(initialValue: VMConfig.toGB(size: vmMemory).formatted())
	}

	var body: some View {
		NavigationStack{
			Text("Configure '\(config.name)'")
				.font(.system(size: 35, weight: .medium, design: .default))
			HStack {
				VStack {
					VStack(alignment: .leading, spacing: 20) {
						TextField("VM Name", text: $vmName)
							.font(.system(size: defFontSize, weight: .medium, design: .default))
							.textFieldStyle(.roundedBorder)
							.onSubmit {
								DispatchQueue.main.async {
									if viewModel.hasVM(vmName) {
										newVmStatus = .error("A VM named '\(vmName)' already exists.")
										vmName = config.name
									}
									if VMListViewModel.confirmDialog(
										message: "Change VM name",
										informativeText: "Are you shure you want to change the name of: '\(self.config.name)' to '\(vmName)'") {
										do {
											let old = self.config.name
											let oldController = viewModel.vmMap[old]?.controller
											try self.config.rename(to: vmName)
											vmName = config.name
											if let keyToRemove = viewModel.vmMap.first(where: { $0.value.config.name == old })?.key {
												viewModel.vmMap.removeValue(forKey: keyToRemove)
											}
											viewModel.vmMap[old] = nil
											viewModel.vmMap[vmName] = (config: self.config, controller: oldController)
											newVmStatus = .inform("Renamed \(old) to \(self.config.name)")
										} catch {
											newVmStatus = .error("Failed to rename VM: \(error.localizedDescription)")
										}
									}
									vmName = config.name
								}
							}.frame(maxWidth: 400)
						HStack {
							Image(systemName: "cpu.fill")
								.font(.system(size: defFontSize, weight: .medium, design: .default))
							Stepper("CPU Count: \(vmCpuCount)", value: $vmCpuCount, in: 1...VMConfig.computeMaxCPUCount())
								.font(.system(size: defFontSize, weight: .medium, design: .default))
								.onChange(of: vmCpuCount) { oldValue, newValue in
									DispatchQueue.main.async {
										do {
											try self.config.setCPUCount(vmCpuCount)
											newVmStatus = .inform("Set CPU count for \(self.config.name) to \(vmCpuCount)")
										} catch {
											newVmStatus = .warning("Failed to set CPU count for VM from \(oldValue) to \(newValue): \(error.localizedDescription)")
										}
									}
								}
							Spacer()
						}
						.frame(maxWidth: 400)
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
									}
								}.onSubmit {
									DispatchQueue.main.async {
										vmMemory = VMConfig.clampMemorySize(size: VMConfig.fromGB(size: Int(vmMemoryGBString) ?? 0))
										vmMemoryGBString = "\(VMConfig.toGB(size: vmMemory))"
										do {
											try self.config.setMemorySize(vmMemory)
											newVmStatus = .inform("Set memory size for \(self.config.name) to \(vmMemoryGBString) GB")
										} catch {
											newVmStatus = .warning("Failed to set memory size for VM: \(error.localizedDescription)")
										}

									}
								}
						}.frame(maxWidth: 400)
						/*
						HStack {
							Text("Set custom efi variable store ")
								.font(.system(size: defFontSize, weight: .medium, design: .default))
							Button {
								let panel = NSOpenPanel()
								panel.canChooseFiles = true
								panel.canChooseDirectories = false
								panel.allowsMultipleSelection = false
								panel.allowedContentTypes = [.data]
								panel.begin { response in
									if response == .OK, let selectedURL = panel.url {
										print("Selected file: \(selectedURL.path)")
										let fileManager = FileManager.default
										let destinationURL = URL(fileURLWithPath: config.EFIVariableStorePath())
										do {
											if fileManager.fileExists(atPath: destinationURL.path) {
												try fileManager.removeItem(at: destinationURL)
											}
											try fileManager.copyItem(at: selectedURL, to: destinationURL)
											newVmStatus = .inform("File copied and overwritten.")
										} catch {
											newVmStatus = .warning("Failed to copy EFI Variable Store: \(error)")
										}
									} else {
										newVmStatus = .warning("No file selected")
									}
								}
							} label: {
								Image(systemName: "folder.fill.badge.plus")
									.font(.system(size: defFontSize + 10, weight: .medium, design: .default))
							}
							//.buttonStyle(.borderless)
							.contentShape(Rectangle())
							.help("Set custom efi variable store")
							.font(.system(size: defFontSize, weight: .medium, design: .default))
							.onHover { hovering in
								if (hovering) { NSCursor.pointingHand.push() } else { NSCursor.pop() }
							}
							Spacer()
						}.frame(maxWidth: 400)
						 */
						HStack {
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
											.font(.system(size: defFontSize, weight: .medium, design: .default))
											.foregroundColor(.red)
											.scaleEffect(bounce ? 1.2 : 1.0)
											.animation(.interpolatingSpring(stiffness: 300, damping: 5), value: bounce)
											.contentShape(Rectangle())
											.help(string)
											.onAppear {
												NSSound(named: NSSound.Name("Submarine"))?.play()
												bounce = true
											}
										Text(string)
											.lineLimit(1)
											.truncationMode(.tail)
											.font(.system(size: defFontSize - 2, weight: .medium, design: .default))
									}
								case .warning(let string):
									HStack(spacing: 4) {
										Image(systemName: "exclamationmark.triangle.fill")
											.foregroundColor(.yellow)
											.scaleEffect(bounce ? 1.2 : 1.0)
											.animation(.interpolatingSpring(stiffness: 300, damping: 5), value: bounce)
											.font(.system(size: defFontSize, weight: .medium, design: .default))
											.contentShape(Rectangle())
											.help(string)
											.onAppear {
												bounce = true
											}
										Text(string)
											.lineLimit(1)
											.truncationMode(.tail)
											.font(.system(size: defFontSize - 2, weight: .medium, design: .default))
									}
								case .inform(let string):
									HStack(spacing: 4) {
										Image(systemName: "exclamationmark.triangle.fill")
											.foregroundColor(.blue)
											.scaleEffect(bounce ? 1.2 : 1.0)
											.animation(.interpolatingSpring(stiffness: 300, damping: 5), value: bounce)
											.font(.system(size: defFontSize, weight: .medium, design: .default))
											.contentShape(Rectangle())
											.help(string)
											.onAppear {
												bounce = true
											}
										Text(string)
											.lineLimit(1)
											.truncationMode(.tail)
											.font(.system(size: defFontSize, weight: .medium, design: .default))
									}
								}
							}
						}
					}
				}
				.padding()
				.frame(maxWidth: 500)
				VStack(alignment: .trailing, spacing: 12) {
					GroupBox("Mount Points") {
						Table(config.mountPoints) {
							TableColumn("Host Path") { point in
								Text(point.path)
							}
							.width(min: 150, ideal: 150, max: .infinity)
							TableColumn("Tag") { point in
								Text(point.tag)
							}
							.width(min: 60, ideal: 60, max: .infinity)
							TableColumn("") { point in
								Button(role: .destructive) {
									config.removeMountPoint(point)
									refreshTrigger += 1
								} label: {
									Image(systemName: "trash")
								}
								.buttonStyle(.borderless)
								.help("Delete this mount point")
							}
							.width(min: 15, ideal: 15, max: 15)
						}
						.id(refreshTrigger)
						.frame(minHeight: 150)
					}
					.contentShape(Rectangle())
					.help("mount -t virtiofs host-share /mnt/point")
					Divider()

					HStack {
						Button(action: {
							let panel = NSOpenPanel()
							panel.canChooseFiles = true
							panel.canChooseDirectories = true
							panel.allowsMultipleSelection = false
							panel.allowedContentTypes = [.directory]
							panel.begin { response in
								if response == .OK, let selectedURL = panel.url {
									print("Selected file: \(selectedURL.path)")
									newPath = selectedURL.path
								} else {
									newVmStatus = .warning("No file selected")
								}
							}
						}) {
							Image(systemName: "folder.fill.badge.plus")
								.font(.title2)
						}
						TextField("Path", text: $newPath)
							.textFieldStyle(.roundedBorder)
						TextField("Tag", text: $newTag)
							.textFieldStyle(.roundedBorder)

						Button(action: {
							guard !newPath.isEmpty, !newTag.isEmpty else { return }
							config.addMountPoint(HostMountPoint(path: newPath, tag: newTag))
							newPath = ""
							newTag = ""
						}) {
							Image(systemName: "plus.circle.fill")
								.font(.title2)
						}
						.buttonStyle(.plain)
						.help("Add new mount point")
					}
				}
				.padding()
				.frame(maxWidth: 700)
			}
			.frame(maxWidth: 1500)
		}
	}
}

#Preview {
}
