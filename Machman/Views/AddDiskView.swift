//
//  AddDiskView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-01.
//

import SwiftUI
import MachmanUI
import Foundation
import MachmanAPI
extension View {
	func placeholder<Content: View>(
		when shouldShow: Bool,
		alignment: Alignment = .leading,
		@ViewBuilder placeholder: () -> Content
	) -> some View {
		ZStack(alignment: alignment) {
			if shouldShow {
				placeholder().padding(.horizontal, 4)
			}
			self
		}
	}
}

struct AddDiskView: View {
	@State private var name: String = ""
	@State private var iso: String = ""
	@State private var disk: String = ""
	@State private var size: String = ""
	@State private var vmDiskSize: UInt64 = 0
	@State private var vmDiskSizeStringGB: String = ""
	// Free space on the VM data volume, from HostCapabilities (the engine's side of the API).
	var freeGB: Int? = nil
	var addIso: (URL) -> Void = { _ in }
	var addFrom: (URL) -> Void = { _ in }
	var addNew: (_ name: String, _ size: UInt64) -> Void = { _,_  in }
	var body: some View {
			TabView {
				VStack {
					HStack {
						Image(systemName: MachmanSymbols.diskName)
							.foregroundColor(.secondary)
						TextField("Name", text: $name)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						Image(systemName: MachmanSymbols.diskSize)
							.foregroundColor(.secondary)
						TextField("", text: $size)
							.textFieldStyle(.roundedBorder)
							.onReceive(size.publisher.collect()) { chars in
								DispatchQueue.main.async {
									size = String(size.prefix(4).filter { "0123456789".contains($0) })
									if (Int(size) ?? 0 > freeGB ?? Int.max) {
										size = (freeGB ?? Int.max).formatted()
									}
								}
							}
							.placeholder(when: size.isEmpty) {
								Text("Size GB (max \(freeGB ?? 0) GB)")
									.padding(.horizontal)
											.foregroundColor(.secondary)
						}
					}
					//.pickerStyle(.inline)
					Divider()
					HStack {
						IconButton(
							symbol: MachmanSymbols.add,
							tooltip: "Create the disk image and attach it"
						) {
							addNew(name, ByteSize.fromGB(Int(size) ?? 0))
						}
						.padding(.trailing)
						Text("Add new disk")
						Spacer()
					}
				}.padding()
				.tabItem {
					Label("new", systemImage: MachmanSymbols.diskStorage)
				}

				VStack {
					HStack {
						IconButton(
							symbol: MachmanSymbols.browse,
							tooltip: "Choose an ISO image",
							font: .title2
						) {
							let panel = NSOpenPanel()
							panel.canChooseFiles = true
							panel.canChooseDirectories = true
							panel.allowsMultipleSelection = false
							panel.allowedContentTypes = [.diskImage]
							panel.begin { response in
								if response == .OK, let selectedURL = panel.url {
									iso = selectedURL.path
								}
							}
						}
						TextField("iso file", text: $iso)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						IconButton(
							symbol: MachmanSymbols.add,
							tooltip: "Attach the ISO as a boot disk"
						) {
							addIso(URL(fileURLWithPath: iso))
						}
						.padding(.trailing)
						Text("Add new iso boot disk")
						Spacer()
					}
				}.padding()
					.tabItem {
						// Glyphs are semantically crossed vs the disks table (this tab is about
						// ISOs but wears the image glyph; the "browse" tab wears the ISO one).
						// The sweep preserves today's look — fixing is a deliberate change.
						Label("iso boot drive", systemImage: MachmanSymbols.diskImage)
					}

				VStack {
					HStack {
						IconButton(
							symbol: MachmanSymbols.browse,
							tooltip: "Choose a disk image",
							font: .title2
						) {
							let panel = NSOpenPanel()
							panel.canChooseFiles = true
							panel.canChooseDirectories = true
							panel.allowsMultipleSelection = false
							panel.allowedContentTypes = [.diskImage]
							panel.begin { response in
								if response == .OK, let selectedURL = panel.url {
									disk = selectedURL.path
								}
							}
						}
						TextField("Path", text: $disk)
							.textFieldStyle(.roundedBorder)
					}
					Divider()
					HStack {
						IconButton(
							symbol: MachmanSymbols.add,
							tooltip: "Attach the disk image"
						) {
							addFrom(URL(fileURLWithPath: disk))
						}
						.padding(.trailing)
						Text("Add disk")
						Spacer()
					}
				}.padding()
					.tabItem {
						Label("browse", systemImage: MachmanSymbols.diskISO)
					}
			}
			.tabViewStyle(.automatic) // or .page, .segmented if you want specific look
	}
}

#Preview {
    AddDiskView()
}
