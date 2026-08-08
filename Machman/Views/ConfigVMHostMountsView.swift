//
//  ConfigVMHostMountsView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct ConfigVMHostMountsView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	@State private var newPath: String = ""
	@State private var newTag: String = ""

	var body: some View {
		GroupBox {
			VStack(alignment: .trailing, spacing: 12) {
				GroupBox {
					Table(vm.mounts) {
						TableColumn("Host Path") { point in
							Text(point.path)
						}
						.width(min: 150, ideal: 150, max: .infinity)
						TableColumn("Tag") { point in
							Text(point.tag)
								.help("mount -t virtiofs \(point.tag) /mnt/point")
						}
						.width(min: 60, ideal: 60, max: .infinity)
						TableColumn("") { point in
							Button(role: .destructive) {
								viewModel.removeMount(vm.name, mountID: point.id)
							} label: {
								Image(systemName: MachmanSymbols.delete)
							}
							.buttonStyle(.borderless)
							.help("Delete this mount point")
						}
						.width(min: 15, ideal: 15, max: 15)
					}
				}
				// No table-wide .help here: it shadows every cell tooltip (the delete button's
				// never showed). The virtiofs hint lives on the Tag cells and field instead.
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
								newPath = selectedURL.path
							}
						}
					}) {
						Image(systemName: MachmanSymbols.browse)
							.font(.title2)
					}
					TextField("Path", text: $newPath)
						.textFieldStyle(.roundedBorder)
					TextField("Tag", text: $newTag)
						.textFieldStyle(.roundedBorder)
						.help("Guest mount tag: mount -t virtiofs <tag> /mnt/point")

					Button(action: {
						guard !newPath.isEmpty, !newTag.isEmpty else { return }
						viewModel.addMount(vm.name, path: newPath, tag: newTag)
						newPath = ""
						newTag = ""
					}) {
						Image(systemName: MachmanSymbols.addFilled)
							.font(.title2)
					}
					.buttonStyle(.plain)
					.help("Add new mount point")
				}
			}
		}
	}
}

#Preview {}
