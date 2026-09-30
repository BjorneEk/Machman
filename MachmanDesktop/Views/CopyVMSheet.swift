//
//  CopyVMSheet.swift
//  MachmanDesktop
//
//  Duplicate a stopped VM: pick a name and which writable disks to carry. ISOs are read-only
//  references and always travel; image disks travel as references to the same file. The
//  space hint is worst case — APFS clones usually share blocks.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct CopyVMSheet: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var newName: String
	@State private var includedDiskIDs: Set<String>

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_newName = State(initialValue: viewModel.defaultCopyName(for: vm.name))
		_includedDiskIDs = State(initialValue:
			Set(vm.disks.filter { $0.type != .iso }.map(\.id)))
	}

	// ISOs always travel by reference; only writable disks are a choice.
	private var writableDisks: [DiskInfo] { vm.disks.filter { $0.type != .iso } }

	// Worst case — only cloned storage disks can cost real space.
	private var bytesNeeded: UInt64 {
		writableDisks
			.filter { $0.type == .storage && includedDiskIDs.contains($0.id) }
			.compactMap(\.sizeBytes)
			.reduce(0, +)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Duplicate \(vm.name)")
				.font(.headline)
			TextField("New name", text: $newName)
				.textFieldStyle(.roundedBorder)
			ForEach(writableDisks) { disk in
				Toggle(isOn: Binding(
					get: { includedDiskIDs.contains(disk.id) },
					set: { include in
						if include {
							includedDiskIDs.insert(disk.id)
						} else {
							includedDiskIDs.remove(disk.id)
						}
					})) {
					Text(disk.name ?? Self.shortPath(disk.path ?? "", 2))
				}
				.toggleStyle(.checkbox)
				.help(disk.type == .storage
					? "Copies the disk file into the new VM"
					: "The copy references the same image file — don't run both on it at once")
			}
			if let free = viewModel.capabilities?.freeDiskBytes {
				Text("Needs up to \(ByteSize.toGB(bytesNeeded)) GB — "
					+ "\(ByteSize.toGB(free)) GB free")
					.font(.caption)
					.foregroundColor(bytesNeeded > free ? .red : .secondary)
			}
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { viewModel.copyRequest = nil }
				// The sheet closes immediately; the corner progress card tracks the copy.
				Button("Duplicate") {
					viewModel.copyVM(vm.name, newName: newName,
						diskIDs: Array(includedDiskIDs).sorted())
				}
				.keyboardShortcut(.defaultAction)
				.disabled(viewModel.copyInFlight || newName.isEmpty
					|| viewModel.hasVM(newName))
			}
		}
		.padding(20)
		.frame(minWidth: 380)
	}

	// Last `n` path components, for compact disk labels ("isos/debian.iso").
	private static func shortPath(_ path: String, _ n: Int) -> String {
		let components = path.split(separator: "/").map(String.init)
		guard n > 0 else { return "" }
		return components.suffix(n).joined(separator: "/")
	}
}
