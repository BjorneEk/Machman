//
//  MainVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
struct EditableText: View {
	@Binding var text: String
	let onSubmit: () -> Void
	let onChange: (String) -> Void

	@State private var isEditing = false
	@FocusState private var isFocused: Bool

	init(
		_ text: Binding<String>,
		onSubmit: @escaping () -> Void = { },
		onChange: @escaping (String) -> Void = { _ in }
	) {
		self._text = text
		self.onSubmit = onSubmit
		self.onChange = onChange

	}


	var body: some View {
		Group {
			if isEditing {
				TextField("", text: $text, onCommit: {
					isEditing = false
					onSubmit()
				})
				//.textFieldStyle(.roundedBorder)
				.focused($isFocused)
				.frame(maxWidth: 200)
				.onAppear {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						isFocused = true
					}
				}
				.onChange(of: text) {
					onChange(text)
				}
			} else {
				Text(text)
					.help("double click to edit")
					.onTapGesture(count: 2) {
						isEditing = true
					}
			}
		}
	}
}

struct MainVMView: View {
	@StateObject private var viewModel: NewVMListViewModel
	@State private var vm: VirtualMachine

	@State private var vmMemory: UInt64
	@State private var vmCpuCount: Int
	@State private var vmMemoryGBString: String
	@State private var vmName: String

	@State private var refreshTrigger = 0

	@State private var newPath: String = ""
	@State private var newTag: String = ""
	@State private var previewImage: NSImage?

	//@Environment(\.dismiss) private var dismiss

	init(viewModel: @autoclosure @escaping () -> NewVMListViewModel = NewVMListViewModel(),
		 selectedItem: VirtualMachine) {
		_viewModel = StateObject(wrappedValue: viewModel())
		vm = selectedItem
		vmMemory = selectedItem.config.memorySize
		vmCpuCount = selectedItem.config.cpuCount
		vmMemoryGBString = VMConfig.toGB(size: selectedItem.config.memorySize).formatted()
		vmName = selectedItem.config.name

	}
	init() {
		let a  = NewVMListViewModel()
		_viewModel = StateObject(wrappedValue: a)
		let b = a.vmList().first!
		vm = b
		vmMemory = b.config.memorySize
		vmCpuCount = b.config.cpuCount
		vmMemoryGBString = VMConfig.toGB(size: b.config.memorySize).formatted()
		vmName = b.config.name
	}

	var body: some View {
		VStack {
			// MARK: row 1

			HStack {
				VStack {
					if let previewImage {
						Image(nsImage: previewImage)
							.resizable()
							.aspectRatio(16/9, contentMode: .fit)
							.padding(.zero)
							.cornerRadius(12)
					} else {
						Rectangle()
							.fill(Color.black)
							.aspectRatio(16/9, contentMode: .fit)
							.padding(.zero)
							.cornerRadius(12)
							.overlay(
								ProgressView()
							)

					}
					Spacer()
				}
				.task {
					vm.captureWindowImageInt { image in
						previewImage = image
					}
				}

				VStack {
					HStack {
						EditableText($vmName)
							.font(.system(size: 25, weight: .medium, design: .default))
							.onSubmit {
								DispatchQueue.main.async {
									if viewModel.hasVM(vmName) {
										vm.log(error: "A VM named '\(vmName)' already exists.")
										vmName = vm.config.name
									}
									if VMListViewModel.confirmDialog(
										message: "Change VM name",
										informativeText: "Are you shure you want to change the name of: '\(self.vm.config.name)' to '\(vmName)'") {
										do {
											let old = self.vm.config.name
											try self.vm.config.rename(to: vmName)
											vmName = vm.config.name
											if let keyToRemove = viewModel.vmMap.first(where: { $0.key == old })?.key {
												viewModel.vmMap.removeValue(forKey: keyToRemove)
											}
											viewModel.vmMap[old] = nil
											viewModel.vmMap[vmName] = vm
											vm.log(message: "Renamed \(old) to \(self.vm.config.name)")
										} catch {
											vm.log(error: "Failed to rename VM: \(error.localizedDescription)")
										}
									}
									vmName = vm.config.name
								}
							}
						Spacer()

					}.padding(.top, 15)
					HStack {
						VMActionButton(
							systemImageName: viewModel.runBtnLbl(c: vm.config).rawValue,
							tooltip: viewModel.runBtnLbl(c: vm.config).running() ? "Stop \(vm.config.name)" : "Run \(vm.config.name)",
							bSize: 40,
							fSize: 35,
							color: viewModel.runBtnLbl(c: vm.config).color(),
							action: {
								DispatchQueue.main.async {
									vm.captureWindowImageInt { image in
										previewImage = image
									}
								}
								viewModel.run(c: vm.config)
							})
						.padding(.top)
						VMActionButton(
							systemImageName: "hammer",
							tooltip: "Build \(vm.config.name)",
							bSize: 40,
							fSize: 35,
							color: .yellow,
							action: {
							viewModel.build(c: vm.config)
						})
						.padding(.leading)
						.padding(.top)
						VMActionButton(
							systemImageName: "photo.badge.arrow.down",
							tooltip: "Update Preview",
							bSize: 35,
							fSize: 30,
							action: {
								DispatchQueue.main.async {
									vm.captureWindowImageInt { image in
										previewImage = image
									}
								}
							})
						.padding(.leading)
						.padding(.top)
						Spacer()
					}
					Spacer()
				}
				.padding()
				VStack {
					HStack{
						Spacer()
						VMActionButton(
							systemImageName: "trash",
							tooltip: "Delete",
							bSize: 12,
							fSize: 12,
							action: {
								DispatchQueue.main.async {
									vm.captureWindowImageInt { image in
										previewImage = image
									}
								}
								viewModel.delete(vm: vm)
								//dismiss()
								vm.log(message: "deleted \(vm.config.name)")
							})
							.padding(2)
					}.padding(0)
					Spacer()
					GroupBox {
						Table(vm.log) {
							TableColumn("Type") { (entry: VirtualMachineLog) in
								switch entry {
								case .message: Text("Message")
								case .warning: Text("Warning")
								case .error: Text("Error")
								}
							}
							TableColumn("Message") { (entry: VirtualMachineLog) in
								switch entry {
								case	.message(let msg),
										.warning(let msg),
										.error(let msg):
									Text(msg)
								}
							}
						}
					}.padding(.bottom, 2)
				}
			}

			// MARK: row 2
			GroupBox {
				HStack {
					HStack {
						Text("\(vmCpuCount)")
							.font(.system(size: 20, weight: .medium, design: .default))
						Image(systemName: "cpu.fill")
							.font(.system(size: 20, weight: .medium, design: .default))
						Stepper("CPUs", value: $vmCpuCount, in: 1...VMConfig.computeMaxCPUCount())
							.font(.system(size: 20, weight: .medium, design: .default))
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
					}.padding(.trailing)
					HStack {
						EditableText($vmMemoryGBString)
							.font(.system(size: 20, weight: .medium, design: .default))
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
							.font(.system(size: 20, weight: .medium, design: .default))
						Text("GB RAM")
							.font(.system(size: 20, weight: .medium, design: .default))
					}
					Spacer()
				}
				.padding(.horizontal)
				.padding(.vertical, 2)
			}
			// MARK: row 2
			//Divider()
			// MARK: Log Section
			GroupBox {
				VStack(alignment: .trailing, spacing: 12) {
					GroupBox {
						Table(vm.config.mountPoints) {
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
									vm.config.removeMountPoint(point)
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
									vm.log(message: "Selected file: \(selectedURL.path)")
									newPath = selectedURL.path
								} else {
									vm.log(error: "No file selected")
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
							vm.config.addMountPoint(HostMountPoint(path: newPath, tag: newTag))
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
			}
		}
		.padding()

	}
}

#Preview {
	MainVMView()
}
