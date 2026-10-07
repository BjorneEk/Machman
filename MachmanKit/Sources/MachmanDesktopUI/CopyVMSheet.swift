//
//  CopyVMSheet.swift
//  MachmanDesktopUI
//
//  Duplicate a stopped VM: pick a name, which writable disks to carry and which mounts to
//  keep. ISOs are read-only references and always travel; image disks travel as references
//  to the same file. The space hint is worst case — APFS clones usually share blocks.
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
	@State private var includedMountIDs: Set<String>

	// `name` pre-fills the field and `excludedMountIDs` unticks mounts (render scenes); the
	// defaults are "<vm> copy" and every mount kept.
	init(
		vm: VMInfo, viewModel: VMListViewModel, name: String? = nil,
		excludedMountIDs: Set<String> = []
	) {
		self.vm = vm
		self.viewModel = viewModel
		_newName = State(initialValue: name ?? viewModel.defaultCopyName(for: vm.name))
		_includedDiskIDs = State(initialValue:
			Set(vm.disks.filter { $0.type != .iso }.map(\.id)))
		_includedMountIDs = State(initialValue:
			Set(vm.mounts.map(\.id)).subtracting(excludedMountIDs))
	}

	private var problem: String? { viewModel.newVMNameProblem(newName) }

	// ISOs always travel by reference; only writable disks are a choice.
	private var writableDisks: [DiskInfo] { vm.disks.filter { $0.type != .iso } }

	// A copied disk keeps its guest's machine id and DHCP client id (Linux's, dhcpcd's on the
	// BSDs): the copy's Guest Setup run gives it its own (S55), but only knows it is a copy
	// when its source ran Guest Setup — a never-set-up guest's copy isn't recognized (S57).
	private var storageDiskHelp: String {
		vm.boot.mode == .macOS
			? "Copies the disk file into the new VM"
			: "Copies the disk file into the new VM — if this VM has run Guest Setup, run it "
				+ "again in the copy so the copy leases its own address"
	}

	// Worst case — only cloned storage disks can cost real space.
	private var bytesNeeded: UInt64 {
		writableDisks
			.filter { $0.type == .storage && includedDiskIDs.contains($0.id) }
			.compactMap(\.sizeBytes)
			.reduce(0, +)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Duplicate “\(vm.name)”")
				.font(.headline)
				.lineLimit(1)
				.truncationMode(.middle)
			TextField("New name", text: $newName)
				.textFieldStyle(.roundedBorder)
			if let problem {
				FieldProblem(problem)
			}
			if !writableDisks.isEmpty {
				Text("Disks")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
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
					// A long name or reference path truncates in the middle; the sheet keeps
					// its width.
					Text(disk.name ?? Self.shortPath(disk.path ?? "", 2))
						.lineLimit(1)
						.truncationMode(.middle)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.toggleStyle(.checkbox)
				.help(disk.type == .storage
					? storageDiskHelp
					: "The copy references the same image file — don’t run both on it at once")
			}
			if !vm.mounts.isEmpty {
				Text("Mounts")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			ForEach(vm.mounts) { mount in
				Toggle(isOn: Binding(
					get: { includedMountIDs.contains(mount.id) },
					set: { include in
						if include {
							includedMountIDs.insert(mount.id)
						} else {
							includedMountIDs.remove(mount.id)
						}
					})) {
					// Capped: a deep path truncates in the middle instead of widening the sheet.
					Text((mount.path as NSString).abbreviatingWithTildeInPath)
						.lineLimit(1)
						.truncationMode(.middle)
						.frame(maxWidth: 300, alignment: .leading)
				}
				.toggleStyle(.checkbox)
				.help("The copy shares this folder with its guest as \u{201C}\(mount.tag)\u{201D}")
			}
			if let free = viewModel.capabilities?.freeDiskBytes {
				Text(bytesNeeded > 0
					? "Needs up to \(ByteSize.display(bytesNeeded)) — "
						+ "\(ByteSize.display(free)) free"
					: "\(ByteSize.display(free)) free")
					.font(.caption)
					.foregroundColor(bytesNeeded > free ? MachmanColors.problem : .secondary)
			}
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { viewModel.copyRequest = nil }
					.keyboardShortcut(.cancelAction)
				// The sheet closes immediately; the corner progress card tracks the copy.
				Button("Duplicate") {
					viewModel.submitCopy(
						vm, name: newName, diskIDs: Array(includedDiskIDs).sorted(),
						mountIDs: VMListViewModel.copyMountIDs(
							for: vm, included: includedMountIDs))
				}
				.keyboardShortcut(.defaultAction)
				.disabled(viewModel.copyInFlight || problem != nil)
			}
		}
		.padding(20)
		.frame(width: 400)
	}

	// Last `n` path components, for compact disk labels ("isos/debian.iso").
	private static func shortPath(_ path: String, _ n: Int) -> String {
		let components = path.split(separator: "/").map(String.init)
		guard n > 0 else { return "" }
		return components.suffix(n).joined(separator: "/")
	}
}
