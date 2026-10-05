//
//  TreeStorageSection.swift
//  MachmanDesktopUI
//
//  The device tree's Disks and Mounts sections (VMDeviceTreeView).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TreeStorageSection: View {
	let ctx: TreeContext
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		diskGroup
		mountGroup
	}

	@ViewBuilder
	private var diskGroup: some View {
		let disks = ctx.sectionRows(.disks, ctx.vm.disks) { ctx.matches($0.name, $0.path) }
		if ctx.shows(.disks, rows: disks.count) {
			TreeGroup(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
				count: ctx.vm.disks.count, isExpanded: ctx.groupBinding(.group("Disks")), menu: {
					Button("Add Existing Disk…") {
						AddFlows.chooseExistingDisk(viewModel: ctx.viewModel, vm: ctx.vm.name)
					}
					Button("Paste") { ctx.paste(into: .disks) }
						.disabled(!ctx.pasteboard.snapshot.canPaste(into: .disks))
				}) {
				ForEach(disks) { disk in
					HStack(spacing: 6) {
						Image(systemName: Self.symbol(for: disk.type))
							.font(.system(size: theme.metrics.iconSize))
							.foregroundStyle(disk.owned == false ? Color.secondary : Color.primary)
						if ctx.renamingNode == .disk(disk.id) {
							RenameField(initial: disk.name ?? "") { newName in
								ctx.renamingNode = nil
								ctx.viewModel.renameDisk(
									ctx.vm.name, diskID: disk.id, newName: newName)
							} cancel: {
								if ctx.renamingNode == .disk(disk.id) { ctx.renamingNode = nil }
							}
						} else {
							Text(disk.name ?? Self.lastComponent(disk.path))
								.truncationMode(.middle)
								.lineLimit(1)
						}
						Spacer()
						if disk.owned == false {
							Image(systemName: MachmanSymbols.externalReference)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help("Referenced — lives outside the VM directory")
						}
					}
					.treeRow(
						.disk(disk.id),
						opacity: disk.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity
					) { ctx.diskMenu(disk) }
				}
				ctx.dropPreview(in: .disks, icon: MachmanSymbols.diskStorage)
			}
			.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.disks))
		}
	}

	@ViewBuilder
	private var mountGroup: some View {
		let mounts = ctx.sectionRows(.mounts, ctx.vm.mounts) { ctx.matches($0.path, $0.tag) }
		if ctx.shows(.mounts, rows: mounts.count) {
			TreeGroup(.group("Mounts"), symbol: MachmanSymbols.mount, title: "Mounts",
				count: ctx.vm.mounts.count, isExpanded: ctx.groupBinding(.group("Mounts")),
				menu: {
					Button("Add Mount Folder…") {
						AddFlows.chooseMountFolder(viewModel: ctx.viewModel, vm: ctx.vm.name)
					}
					Button("Paste") { ctx.paste(into: .mounts) }
						.disabled(!ctx.pasteboard.snapshot.canPaste(into: .mounts))
				}) {
				ForEach(mounts) { mount in
					HStack(spacing: 6) {
						Image(systemName: MachmanSymbols.mount)
							.font(.system(size: theme.metrics.iconSize))
						Text(Self.abbreviate(mount.path))
							.truncationMode(.middle)
							.lineLimit(1)
							.help("\(mount.path) — guest tag “\(mount.tag)”")
						Spacer()
						// Trailing badges (the disks' externalReference pattern): how the
						// mount travels, and whether the guest mounts it at boot.
						if mount.effectiveKind == MountKind.sshfs {
							Image(systemName: MachmanSymbols.mountSSHFS)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help("sshfs — the guest mounts this over its SSH link")
						}
						if mount.automounted == true {
							Image(systemName: MachmanSymbols.automounted)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help(mount.automountedAt.map { "Mounts at boot at \($0)" }
									?? "Mounted at boot by Guest Setup")
						}
					}
					.treeRow(
						.mount(mount.id),
						opacity: mount.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity
					) { ctx.mountMenu(mount) }
				}
				ctx.dropPreview(in: .mounts, icon: MachmanSymbols.mount)
			}
			.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.mounts))
		}
	}

	// MARK: - Helpers

	private static func symbol(for type: DiskType) -> String {
		switch type {
		case .storage: return MachmanSymbols.diskStorage
		case .image: return MachmanSymbols.diskImage
		case .iso: return MachmanSymbols.diskISO
		case .unknown: return MachmanSymbols.help
		}
	}

	private static func lastComponent(_ path: String?) -> String {
		path.map { ($0 as NSString).lastPathComponent } ?? "disk"
	}

	private static func abbreviate(_ path: String) -> String {
		(path as NSString).abbreviatingWithTildeInPath
	}
}
