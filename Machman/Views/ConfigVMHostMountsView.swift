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
							IconButton(
								symbol: MachmanSymbols.delete,
								tooltip: "Delete this mount point",
								flat: true,
								role: .destructive
							) {
								viewModel.removeMount(vm.name, mountID: point.id)
							}
						}
						.width(min: 15, ideal: 15, max: 15)
					}
				}
				// No table-wide .help here: it shadows every cell tooltip (the delete button's
				// never showed). The virtiofs hint lives on the Tag cells and field instead.
				Divider()

				HStack {
					IconButton(
						symbol: MachmanSymbols.browse,
						tooltip: "Choose a folder to share",
						font: .title2
					) {
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
					}
					TextField("Path", text: $newPath)
						.textFieldStyle(.roundedBorder)
					TextField("Tag", text: $newTag)
						.textFieldStyle(.roundedBorder)
						.help("Guest mount tag: mount -t virtiofs <tag> /mnt/point")

					IconButton(
						symbol: MachmanSymbols.addFilled,
						tooltip: "Add new mount point",
						font: .title2
					) {
						guard !newPath.isEmpty, !newTag.isEmpty else { return }
						viewModel.addMount(vm.name, path: newPath, tag: newTag)
						newPath = ""
						newTag = ""
					}
				}
				// Absorbs the stretched height from the top-aligned row in MainVMView so the
				// table doesn't inflate.
				Spacer()
			}
		}
		.padding(2)
	}
}

#Preview {}
