//
//  EntityInspectors.swift
//  MachmanDesktopUI
//
//  Disk and mount inspectors (1.0.4 UI), grounded in the wire: an owned disk's name and a
//  mount's tag rename in place (vm.disk.rename / vm.mount.setTag, the reason under the
//  field), safety/enabled ride vm.setSafety / vm.setEnabled, grow is vm.disk.resize (owned
//  storage, stopped VM only), promote copies a referenced image in. The mount inspector
//  shows where the folder lands in the guest; the per-OS steps are MountHelpSheet's.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// MARK: - Disk --------------------------------------------------------------------------------

struct DiskInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let diskID: String
	@State private var growText: String
	@State private var draftName = ""
	// The daemon's reason for refusing the last rename, until the next edit.
	@State private var renameRefusal: String?
	private let initialNameDraft: String?

	// `growText` opens the Grow-to field on a typed size, `nameDraft` the Name field on an
	// unsent draft and `refusal` with the daemon's reason under it (render scenes).
	init(
		viewModel: VMListViewModel, vm: VMInfo, diskID: String, growText: String = "",
		nameDraft: String? = nil, refusal: String? = nil
	) {
		self.viewModel = viewModel
		self.vm = vm
		self.diskID = diskID
		_growText = State(initialValue: growText)
		initialNameDraft = nameDraft
		_renameRefusal = State(initialValue: refusal)
	}

	var body: some View {
		if let disk = vm.disks.first(where: { $0.id == diskID }) {
			Form {
				Section("Info") {
					if disk.type == .storage && disk.owned != false {
						nameField(disk)
					} else {
						LabeledContent("Name", value: disk.name ?? fileName(disk))
					}
					if let size = disk.sizeBytes {
						LabeledContent("Size", value: ByteSize.display(size))
							.help("\(size.formatted()) bytes")
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
						growRow(disk)
					}
					HStack(spacing: 6) {
						if disk.owned == false {
							IconButton(
								symbol: MachmanSymbols.promoteDisk,
								tooltip: vm.refusal(.promoteDisk)
									?? "Promote to owned — copies the image into the "
									+ "VM directory"
							) {
								viewModel.promoteDisk(vm.name, diskID: diskID)
							}
							.disabled(vm.refusal(.promoteDisk) != nil)
						}
						IconButton(
							symbol: MachmanSymbols.delete,
							tooltip: vm.refusal(.removeDisk) ?? (disk.owned == true
								? "Delete… (removes the file)" : "Disconnect (file is kept)")
						) {
							remove(disk)
						}
						.disabled(vm.refusal(.removeDisk) != nil)
						Spacer()
					}
				}
			}
		} else {
			NoSelectionInspector()
		}
	}

	// The VM Name field's pattern: the reason under the field while it is typed, Return
	// sends nothing then; a daemon refusal restores the name and keeps its reason (PR8).
	private func nameField(_ disk: DiskInfo) -> some View {
		let current = disk.name ?? ""
		let problem = renameRefusal
			?? viewModel.diskRenameProblem(draftName, diskID: diskID, on: vm)
		return VStack(alignment: .leading, spacing: 3) {
			TextField("Name", text: $draftName)
				.onSubmit { commitRename(disk) }
				.disabled(vm.refusal(.renameDisk) != nil)
				.help(vm.refusal(.renameDisk) ?? "Renames the backing file too")
			if let problem {
				FieldProblem(problem)
			}
		}
		.onAppear { draftName = initialNameDraft ?? current }
		.onChange(of: disk.name) { draftName = disk.name ?? "" }
		.onChange(of: draftName) {
			if draftName != current { renameRefusal = nil }
		}
	}

	private func commitRename(_ disk: DiskInfo) {
		let current = disk.name ?? ""
		let sent = viewModel.submitDiskRename(vm, diskID: diskID, draft: draftName) { reason in
			draftName = current
			renameRefusal = reason
		}
		// Only padded, or unchanged: tidy the field back to the name.
		if !sent, viewModel.diskRenameProblem(draftName, diskID: diskID, on: vm) == nil {
			draftName = current
		}
	}

	private func typeLabel(_ disk: DiskInfo) -> String {
		switch disk.type {
		case .storage: return "Owned storage"
		case .image: return disk.owned == false ? "Referenced disk image" : "Disk image"
		case .iso: return "ISO (read-only USB storage)"
		case .unknown: return "Unknown disk type"
		}
	}

	private func fileName(_ disk: DiskInfo) -> String {
		disk.path.map { ($0 as NSString).lastPathComponent } ?? disk.id
	}

	// The target size, not a step: the Size row above says where it starts. No default
	// action on Grow — Return belongs to the field, never to the window.
	private func growRow(_ disk: DiskInfo) -> some View {
		let problem = viewModel.growDiskProblem(growText, disk: disk)
		let typed = !growText.trimmingCharacters(in: .whitespaces).isEmpty
		return VStack(alignment: .leading, spacing: 3) {
			LabeledContent("Grow to") {
				HStack(spacing: 6) {
					TextField("", text: $growText, prompt: Text("New size"))
						.textFieldStyle(.roundedBorder)
						.multilineTextAlignment(.trailing)
						.frame(width: 80)
						.onSubmit(grow)
					Button("Grow", action: grow)
						.disabled(!typed || problem != nil)
				}
			}
			if let problem {
				FieldProblem(problem)
			}
		}
		.disabled(vm.refusal(.resizeDisk) != nil)
		.help(vm.refusal(.resizeDisk) ?? "Disks only grow; a bare number is GB")
	}

	private func grow() {
		if viewModel.submitGrowDisk(vm, diskID: diskID, text: growText) {
			growText = ""
		}
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
	// The daemon's reason for refusing the last tag change, until the next edit.
	@State private var tagRefusal: String?
	@State private var showGuide = false
	private let initialTagDraft: String?

	// `tagDraft` opens the Tag field on an unsent draft (render scenes).
	init(viewModel: VMListViewModel, vm: VMInfo, mountID: String, tagDraft: String? = nil) {
		self.viewModel = viewModel
		self.vm = vm
		self.mountID = mountID
		initialTagDraft = tagDraft
	}

	var body: some View {
		if let mount = vm.mounts.first(where: { $0.id == mountID }) {
			Form {
				Section("Info") {
					tagField(mount)
					PathRow(label: "Host path", path: mount.path) {
						NSWorkspace.shared.activateFileViewerSelecting(
							[URL(fileURLWithPath: mount.path)])
					}
					// macOS guests have no kind choice: the share automounts, and sshfs
					// would need macFUSE (the daemon refuses it too).
					if vm.boot.mode != .macOS {
						Picker("Kind", selection: Binding(
							get: { mount.effectiveKind },
							set: { viewModel.setMountKind(
								vm.name, mountID: mountID, kind: $0) })) {
							Text("virtiofs").tag(MountKind.virtiofs)
							Text("sshfs").tag(MountKind.sshfs)
						}
						.help("virtiofs rides the share device; sshfs is mounted by the "
							+ "guest over its SSH link (no driver needed)")
						if mount.effectiveKind == MountKind.sshfs,
							vm.ssh?.sshfsAvailable != true {
							Text("The guest hasn’t reported sshfs yet — run Guest Setup in it.")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					Toggle("Attach in safe runs", isOn: Binding(
						get: { mount.safe },
						set: { viewModel.setMountSafety(vm.name, mountID: mountID, safe: $0) }))
					Toggle("Enabled", isOn: Binding(
						get: { mount.isEnabled },
						set: { viewModel.setEnabled(vm.name, mounts: [mountID: $0]) }))
				}
				Section("In the guest") {
					if mount.automounted == true {
						LabeledContent {
							Text(mount.automountedAt ?? "At boot")
								.font(.system(.caption, design: .monospaced))
								.foregroundStyle(.secondary)
								.textSelection(.enabled)
						} label: {
							Label("Automount", systemImage: MachmanSymbols.automounted)
						}
					} else {
						let path = GuestSetupCommands.guestPath(of: mount, on: vm)
						LabeledContent("Guest path") {
							HStack(spacing: 2) {
								Text(path)
									.font(.system(.caption, design: .monospaced))
									.truncationMode(.middle)
									.lineLimit(1)
									.help(path)
								CopyToClipboardButton(path, tooltip: "Copy path")
							}
						}
					}
					if let caption = guestCaption(mount) {
						Text(caption)
							.font(.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					GuideButton(
						isPresented: $showGuide, help: "How to reach this folder from the guest")
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
			.sheet(isPresented: $showGuide) {
				MountHelpSheet(vm: vm, mount: mount).liveWhileSettingsLocked()
			}
		} else {
			NoSelectionInspector()
		}
	}

	// The VM Name field's pattern (PR8): the reason under the field, no alert.
	private func tagField(_ mount: MountInfo) -> some View {
		let problem = tagRefusal
			?? viewModel.mountTagProblem(draftTag, mountID: mountID, on: vm)
		return VStack(alignment: .leading, spacing: 3) {
			TextField("Tag", text: $draftTag)
				.onSubmit { commitTag(mount) }
				.help("The name guests see this folder under (applies at the next boot)")
			if let problem {
				FieldProblem(problem)
			}
		}
		.onAppear { draftTag = initialTagDraft ?? mount.tag }
		.onChange(of: mount.tag) { draftTag = mount.tag }
		.onChange(of: draftTag) {
			if draftTag != mount.tag { tagRefusal = nil }
		}
	}

	private func commitTag(_ mount: MountInfo) {
		let sent = viewModel.submitMountTag(vm, mountID: mountID, draft: draftTag) { reason in
			draftTag = mount.tag
			tagRefusal = reason
		}
		// Only padded, or unchanged: tidy the field back to the tag.
		if !sent, viewModel.mountTagProblem(draftTag, mountID: mountID, on: vm) == nil {
			draftTag = mount.tag
		}
	}

	// One sentence on how the folder reaches the guest; the steps live in the guide.
	private func guestCaption(_ mount: MountInfo) -> String? {
		if mount.effectiveKind == MountKind.sshfs {
			return "The guest mounts it over SSH once you approve guest → Mac access in the "
				+ "SSH section."
		}
		if vm.boot.mode == .macOS { return "macOS 13 and later mount the share on their own." }
		return mount.automounted == true
			? nil : "Mount Machman’s share in the guest to reach this folder."
	}
}
