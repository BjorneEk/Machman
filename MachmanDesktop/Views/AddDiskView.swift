//
//  AddDiskView.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-04-01.
//
//  Two tabs: "new" creates an empty storage disk; "browse" picks any supported image (raw
//  or ISO — the file picker is permissive on purpose, the engine's magic sniff is the real
//  gate) and asks whether to copy it into the VM or reference it in place.
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
	@State private var size: String = ""
	// Free space on the VM data volume, from HostCapabilities (the engine's side of the API).
	var freeGB: Int? = nil
	var addReference: (URL) -> Void = { _ in }
	var addCopy: (URL) -> Void = { _ in }
	var addNew: (_ name: String, _ size: UInt64) -> Void = { _, _ in }

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
						tooltip: "Choose a disk image or ISO",
						font: .title2
					) {
						chooseAndAdd()
					}
					.padding(.trailing)
					Text("Add image or ISO")
					Spacer()
				}
				Divider()
				Text("Raw images and ISOs (qcow2 is not supported). After picking, choose "
					+ "whether the VM gets its own copy or references the file in place. "
					+ "You can also drop a file straight onto the disks table to copy it in.")
					.font(.caption)
					.foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
			}.padding()
			.tabItem {
				Label("browse", systemImage: MachmanSymbols.diskImage)
			}
		}
		.tabViewStyle(.automatic)
	}

	private func chooseAndAdd() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		// Permissive on purpose: extensions lie, the engine sniffs magic bytes.
		panel.allowedContentTypes = [.diskImage, .data]
		panel.begin { response in
			guard response == .OK, let url = panel.url else { return }
			askReferenceOrCopy(url)
		}
	}

	private func askReferenceOrCopy(_ url: URL) {
		let alert = NSAlert()
		alert.messageText = "Add \(url.lastPathComponent)"
		alert.informativeText = "Copy it into the VM (the VM owns an independent copy that "
			+ "travels with it), or reference the original file in place?"
		alert.addButton(withTitle: "Copy into VM")
		alert.addButton(withTitle: "Reference")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			addCopy(url)
		case .alertSecondButtonReturn:
			addReference(url)
		default:
			break
		}
	}
}

#Preview {
	AddDiskView()
}
