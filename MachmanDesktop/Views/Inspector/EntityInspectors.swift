//
//  EntityInspectors.swift
//  MachmanDesktop
//
//  Disk and mount inspectors (1.0.4 UI), grounded in the wire: names and tags are
//  read-only (no rename APIs exist), safety/enabled ride vm.setSafety / vm.setEnabled,
//  grow is vm.disk.resize (owned storage, stopped VM only), promote copies a referenced
//  image in. The mount inspector carries the per-OS virtiofs how-tos.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

// MARK: - Disk --------------------------------------------------------------------------------

struct DiskInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let diskID: String
	@State private var growGB = 0
	@State private var draftName = ""

	var body: some View {
		if let disk = vm.disks.first(where: { $0.id == diskID }) {
			Form {
				Section("Info") {
					if disk.type == .storage && disk.owned != false {
						TextField("Name", text: $draftName)
							.onSubmit { commitRename(disk) }
							.onAppear { draftName = disk.name ?? "" }
							.onChange(of: disk.name) { draftName = disk.name ?? "" }
							.disabled(vm.state.isRunning)
							.help(vm.state.isRunning
								? "Stop the VM to rename its disks"
								: "Renames the backing file too")
					} else {
						LabeledContent("Name", value: disk.name ?? fileName(disk))
					}
					if let size = disk.sizeBytes {
						LabeledContent("Size", value: ByteCountFormatter.string(
							fromByteCount: Int64(size), countStyle: .file))
					}
					LabeledContent("Type", value: typeLabel(disk))
					if let path = disk.path {
						PathRow(label: "Path", path: path) { reveal(path) }
					}
				}
				Section("Behaviour") {
					Toggle("Shadow in safe runs", isOn: safeBinding(disk))
						.help("Safe runs write to a discardable shadow of this disk")
					Toggle("Enabled", isOn: enabledBinding(disk))
						.help("Disabled disks are not attached at the next start")
				}
				Section("Actions") {
					if disk.type == .storage && disk.owned != false {
						LabeledContent("Grow") {
							HStack {
								Stepper("+\(growGB) GB", value: $growGB, in: 0...256, step: 8)
								Button("Apply") { grow(disk) }
									.disabled(growGB == 0 || vm.state.isRunning)
							}
						}
						.help(vm.state.isRunning
							? "Stop the VM to grow its disks" : "Grow-only; shrink refuses")
					}
					HStack(spacing: 6) {
						if disk.owned == false {
							IconButton(
								symbol: MachmanSymbols.promoteDisk,
								tooltip: "Promote to owned — copies the image into the "
									+ "VM directory"
							) {
								viewModel.promoteDisk(vm.name, diskID: diskID)
							}
						}
						IconButton(
							symbol: MachmanSymbols.delete,
							tooltip: disk.owned == true
								? "Delete… (removes the file)" : "Disconnect (file is kept)"
						) {
							remove(disk)
						}
						Spacer()
					}
				}
			}
		} else {
			NoSelectionInspector()
		}
	}

	private func commitRename(_ disk: DiskInfo) {
		let newName = draftName.trimmingCharacters(in: .whitespaces)
		guard !newName.isEmpty, newName != disk.name else {
			draftName = disk.name ?? ""
			return
		}
		viewModel.renameDisk(vm.name, diskID: diskID, newName: newName)
	}

	private func typeLabel(_ disk: DiskInfo) -> String {
		switch disk.type {
		case .storage: return "Owned storage"
		case .image: return disk.owned == false ? "Referenced disk image" : "Disk image"
		case .iso: return "ISO (read-only USB storage)"
		}
	}

	private func fileName(_ disk: DiskInfo) -> String {
		disk.path.map { ($0 as NSString).lastPathComponent } ?? disk.id
	}

	private func grow(_ disk: DiskInfo) {
		guard let current = disk.sizeBytes else { return }
		viewModel.resizeDisk(
			vm.name, diskID: diskID,
			sizeBytes: current + UInt64(growGB) << 30)
		growGB = 0
	}

	private func remove(_ disk: DiskInfo) {
		viewModel.requestRemoveDisk(vm.name, disk: disk)
	}

	private func safeBinding(_ disk: DiskInfo) -> Binding<Bool> {
		Binding(
			get: { disk.safe },
			set: { viewModel.setDiskSafety(vm.name, diskID: diskID, safe: $0) })
	}

	private func enabledBinding(_ disk: DiskInfo) -> Binding<Bool> {
		Binding(
			get: { disk.isEnabled },
			set: { viewModel.setEnabled(vm.name, disks: [diskID: $0]) })
	}

	private func reveal(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}

// MARK: - Mount -------------------------------------------------------------------------------

struct MountInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let mountID: String
	@State private var draftTag = ""

	var body: some View {
		if let mount = vm.mounts.first(where: { $0.id == mountID }) {
			Form {
				Section("Info") {
					TextField("Tag", text: $draftTag)
						.onSubmit { commitTag(mount) }
						.onAppear { draftTag = mount.tag }
						.onChange(of: mount.tag) { draftTag = mount.tag }
						.help("The virtiofs tag guests use to mount this folder "
							+ "(applies at the next boot)")
					PathRow(label: "Host path", path: mount.path) {
						NSWorkspace.shared.activateFileViewerSelecting(
							[URL(fileURLWithPath: mount.path)])
					}
					Toggle("Attach in safe runs", isOn: Binding(
						get: { mount.safe },
						set: { viewModel.setMountSafety(vm.name, mountID: mountID, safe: $0) }))
					Toggle("Enabled", isOn: Binding(
						get: { mount.isEnabled },
						set: { viewModel.setEnabled(vm.name, mounts: [mountID: $0]) }))
				}
				Section("Mounting from the Guest") {
					// One virtiofs device carries every mount, each a subdirectory named
					// by its tag. macOS guests get the automount tag (the share appears
					// on its own); other guests mount "host-share" by hand.
					if vm.boot.mode == .macOS {
						Text("This VM's mounts automount in the guest — each is a folder "
							+ "inside the “My Shared Files” volume (macOS 13+).")
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						guestHelp(
							os: "macOS",
							requirement: "Appears on its own; older guests (macOS 12) "
								+ "mount it manually: mkdir -p ~/shared && mount_virtiofs "
								+ "com.apple.virtio-fs.automount ~/shared",
							command: "/Volumes/My Shared Files/\(mount.tag)")
					} else {
						Text("All mounts ride one virtiofs device tagged “\(GuestPaths.shareTag)”. "
							+ "Mount it once — this folder is the “\(mount.tag)” "
							+ "subdirectory inside it.")
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						guestHelp(
							os: "Linux",
							requirement: "virtiofs is built into kernels ≥ 5.4 "
								+ "(CONFIG_VIRTIO_FS); no extra packages.",
							command: GuestPaths.mountShareCommand)
						Text("FreeBSD guests cannot mount virtiofs shares — no driver.")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}
				Section {
					HStack {
						IconButton(
							symbol: MachmanSymbols.delete,
							tooltip: "Remove mount (folder is kept)"
						) {
							viewModel.removeMount(vm.name, mountID: mountID)
						}
						Spacer()
					}
				}
			}
		} else {
			NoSelectionInspector()
		}
	}

	private func commitTag(_ mount: MountInfo) {
		let tag = draftTag.trimmingCharacters(in: .whitespaces)
		guard !tag.isEmpty, tag != mount.tag else {
			draftTag = mount.tag
			return
		}
		viewModel.setMountTag(vm.name, mountID: mountID, tag: tag)
	}

	private func guestHelp(os: String, requirement: String, command: String) -> some View {
		DisclosureGroup(os) {
			VStack(alignment: .leading, spacing: 6) {
				Text(requirement)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				CommandBlock(command)
			}
			.padding(.vertical, 2)
		}
	}
}
