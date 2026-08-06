//
//  ConfigVMDisksView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct ConfigVMDisksView: View {
	@State private var incr: Int = 0
	@State var vm: VirtualMachine

	init(vm: VirtualMachine) {
		self.vm = vm
	}

	var body: some View {
		VStack {
			GroupBox {
				Table(vm.config.disks) {
					TableColumn("Disks") { (entry: VMDisk) in
						switch entry {
						case .storage(_, _):
							Image(systemName: "externaldrive.fill")
								.contentShape(Rectangle())
								.help("storage drive")
						case .fromUrl(_):
							Image(systemName: "externaldrive.fill.badge.icloud")
								.contentShape(Rectangle())
								.help("drive")
						case .iso(_):
							Image(systemName: "externaldrive.connected.to.line.below.fill")
								.contentShape(Rectangle())
								.help("iso image")
						}
					}
					.width(40)
					TableColumn("Info") { (entry: VMDisk) in
						switch entry {
						case .storage(let n, _):
							Text(n)
						case .fromUrl(let url):
							Text(VMConfig.formatUrl(from: url, 2))
						case .iso(let url):
							Text(VMConfig.formatUrl(from: url, 1))
						}
					}
					TableColumn("size") { (entry: VMDisk) in
						if let size = vm.config.getDiskSize(disk: entry) {
							Text("\(VMConfig.toGB(size: size)) GB")
						} else {
							Text("?")
						}
					}.width(40)
					TableColumn("") { (entry: VMDisk) in
						Button(action: {
							DispatchQueue.main.async {
								if case .storage(let name, _) = entry {
									let url = vm.config.localURL(file: "\(name).raw")
									guard VMListViewModel.confirmDialog(
										message: "Delete disk \(VMConfig.formatUrl(from: url, 2))?",
										informativeText: "\(name) remover do you wish to delete it?")
									else { return }
								}
								do {
									try vm.config.deleteDisk(disk: entry)
								} catch {
									vm.log(error: "Failed to delete disk: \(error)")
								}
								self.incr += 1
							}
						}) {
							Image(systemName: "trash")
								.contentShape(Rectangle())
								.help("Delete")
						}
					}.width(20)
				}.id(incr)
				Divider()
				AddDiskView(
					addIso: {
						self.incr += 1
						do {
							try vm.config.addIsoDisk(isoUrl: $0)
						} catch {
							vm.log(error: "Failed to add iso disk: \(error)")
						}
					},
					addFrom: {
						self.incr += 1
						do {
							try vm.config.addDisk(disk: .fromUrl($0))
						} catch {
							vm.log(error: "Failed to add disk: \(error)")
						}
					}, addNew: {
						self.incr += 1
						do {
							try vm.config.addNewStorageDisk(name: $0, size: $1)
						} catch {
							vm.log(error: "Failed to add storage disk: \(error)")
						}
					})
			}
			.padding(.bottom, 8)
		}
	}
}

#Preview {
}
