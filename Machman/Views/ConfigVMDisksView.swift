//
//  ConfigVMDisksView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI
import MachmanUI
import MachmanAPI

// Last `n` path components, for compact disk labels ("isos/debian.iso").
func shortPath(_ path: String, _ n: Int) -> String {
	let components = path.split(separator: "/").map(String.init)
	guard n > 0 else { return "" }
	return components.suffix(n).joined(separator: "/")
}

struct ConfigVMDisksView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	var body: some View {
		VStack {
			GroupBox {
				Table(vm.disks) {
					TableColumn("Disks") { (entry: DiskInfo) in
						switch entry.type {
						case .storage:
							Image(systemName: MachmanSymbols.diskStorage)
								.contentShape(Rectangle())
								.help("storage drive")
						case .image:
							Image(systemName: MachmanSymbols.diskImage)
								.contentShape(Rectangle())
								.help("drive")
						case .iso:
							Image(systemName: MachmanSymbols.diskISO)
								.contentShape(Rectangle())
								.help("iso image")
						}
					}
					.width(40)
					TableColumn("Info") { (entry: DiskInfo) in
						switch entry.type {
						case .storage:
							Text(entry.name ?? "")
						case .image:
							Text(shortPath(entry.path ?? "", 2))
						case .iso:
							Text(shortPath(entry.path ?? "", 1))
						}
					}
					TableColumn("size") { (entry: DiskInfo) in
						if let size = entry.sizeBytes {
							Text("\(ByteSize.toGB(size)) GB")
						} else {
							Text("?")
						}
					}.width(40)
					TableColumn("") { (entry: DiskInfo) in
						Button(action: {
							DispatchQueue.main.async {
								if entry.type == .storage {
									guard VMListViewModel.confirmDialog(
										message: "Delete disk \(entry.name ?? entry.id).raw?",
										informativeText: "\(entry.name ?? entry.id) remover "
											+ "do you wish to delete it?")
									else { return }
								}
								viewModel.removeDisk(vm.name, diskID: entry.id)
							}
						}) {
							Image(systemName: MachmanSymbols.delete)
								.contentShape(Rectangle())
								.help("Delete")
						}
					}.width(20)
				}
				Divider()
				AddDiskView(
					freeGB: viewModel.capabilities.map { ByteSize.toGB($0.freeDiskBytes) },
					addIso: {
						viewModel.addDisk(vm.name, .iso(path: $0.path))
					},
					addFrom: {
						viewModel.addDisk(vm.name, .image(path: $0.path))
					}, addNew: {
						viewModel.addDisk(vm.name, .storage(name: $0, sizeBytes: $1))
					})
			}
			.padding(.bottom, 8)
		}
	}
}

#Preview {
}
