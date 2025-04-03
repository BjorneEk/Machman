//
//  ConfigVMHostMountsView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct ConfigVMHostMountsView: View {
	@State var vm: VirtualMachine
	@State private var refreshTrigger = 0

	@State private var newPath: String = ""
	@State private var newTag: String = ""

	init(vm: VirtualMachine) {
		self.vm = vm
	}

	var body: some View {
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
			//.padding()
		}
	}
}

#Preview {}
