//
//  ConfigVMDisksView.swift
//  MachmanDesktop
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
						HStack(spacing: 4) {
							switch entry.type {
							case .storage:
								Image(systemName: MachmanSymbols.diskStorage)
									.contentShape(Rectangle())
									.help("storage drive")
							case .image:
								Image(systemName: MachmanSymbols.diskImage)
									.contentShape(Rectangle())
									.help("disk image")
							case .iso:
								Image(systemName: MachmanSymbols.diskISO)
									.contentShape(Rectangle())
									.help("iso image")
							}
							// The safe-mode flip-flop rides beside the type glyph:
							// clone-vs-real-file for safe runs.
							IconButton(
								symbol: entry.safe
									? MachmanSymbols.safe : MachmanSymbols.unsafe,
								tooltip: entry.safe
									? "Safe: safe runs use a discardable clone of this disk"
									: "Unsafe: safe runs write to the real file",
								flat: true
							) {
								viewModel.setDiskSafety(
									vm.name, diskID: entry.id, safe: !entry.safe)
							}
						}
					}
					.width(64)
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
						if let path = entry.path {
							CopyToClipboardButton(path, tooltip: "Copy disk path")
						}
					}.width(20)
					TableColumn("") { (entry: DiskInfo) in
						// Promote: copy a referenced external disk into the VM. Hidden for
						// owned disks and when an old daemon doesn't report ownership.
						if entry.owned == false {
							IconButton(
								symbol: MachmanSymbols.promoteDisk,
								tooltip: "Copy this disk into the VM "
									+ "(the VM gets its own independent copy)",
								flat: true
							) {
								DispatchQueue.main.async {
									guard VMListViewModel.confirmDialog(
										message: "Copy this disk into \(vm.name)?",
										informativeText: "The VM gets its own independent "
											+ "copy; the original file stays untouched.")
									else { return }
									viewModel.promoteDisk(vm.name, diskID: entry.id)
								}
							}
						}
					}.width(20)
					TableColumn("") { (entry: DiskInfo) in
						// Ownership = residency: owned files die with their entry, external
						// files only disconnect.
						IconButton(
							symbol: MachmanSymbols.delete,
							tooltip: entry.owned == true
								? "Delete disk file" : "Disconnect (file is kept)",
							flat: true
						) {
							DispatchQueue.main.async {
								if entry.owned == true {
									guard VMListViewModel.confirmDialog(
										message: "Delete disk \(entry.name ?? entry.id)?",
										informativeText: "The backing file belongs to "
											+ "\(vm.name) and will be deleted with it.")
									else { return }
								}
								viewModel.removeDisk(vm.name, diskID: entry.id)
							}
						}
					}.width(20)
				}
				Divider()
				AddDiskView(
					freeGB: viewModel.capabilities.map { ByteSize.toGB($0.freeDiskBytes) },
					addReference: { url in
						// Extension picks the reference kind; the copy path sniffs instead.
						if url.pathExtension.lowercased() == "iso" {
							viewModel.addDisk(vm.name, .iso(path: url.path))
						} else {
							viewModel.addDisk(vm.name, .image(path: url.path))
						}
					},
					addCopy: { url in
						viewModel.importDisk(vm.name, path: url.path)
					},
					addNew: {
						viewModel.addDisk(vm.name, .storage(name: $0, sizeBytes: $1))
					})
			}
			.dropDestination(for: URL.self) { urls, _ in
				// Drop-to-copy (user spec): dropped files are imported as owned copies;
				// the engine's sniff rejects unsupported formats with a presented error.
				guard !urls.isEmpty else { return false }
				for url in urls {
					viewModel.importDisk(vm.name, path: url.path)
				}
				return true
			}
			.padding(.bottom, 8)
		}
	}
}

#Preview {
}
