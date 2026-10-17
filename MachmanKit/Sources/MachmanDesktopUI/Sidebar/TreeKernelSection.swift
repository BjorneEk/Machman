//
//  TreeKernelSection.swift
//  MachmanDesktopUI
//
//  The device tree's Kernel and Initramfs sections (VMDeviceTreeView).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TreeKernelSection: View {
	let ctx: TreeContext
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		if ctx.vm.showsKernelSections {
			kernelGroup(role: .kernel)
			kernelGroup(role: .initramfs)
		}
	}

	// The sections show while kernel boot is on, or while the draft holds something
	// (VMInfo.showsKernelSections: parked, dimmed, in any other boot mode); their rows are
	// VMInfo.kernelTreeEntries.

	@ViewBuilder
	private func kernelGroup(role: KernelRole) -> some View {
		let section: TreeSection = role == .kernel ? .kernel : .initramfs
		let entries = ctx.sectionRows(section, ctx.vm.kernelTreeEntries(role: role)) {
			ctx.matches($0.label)
		}
		if ctx.shows(section, rows: entries.count) {
			kernelDisclosure(role: role, title: section.title, entries: entries)
		}
	}

	@ViewBuilder
	private func kernelDisclosure(
		role: KernelRole, title: String, entries: [KernelTreeEntry]
	) -> some View {
		// Kernel parent is selectable (it has an inspector); the initramfs parent is a dim
		// unselectable group like the others. Both park (extra dim) while kernel boot is off.
		TreeGroup(
			.group(title), title: title, count: nil, selectable: role == .kernel,
			parked: ctx.vm.kernelParkedReason,
			folds: TreeSection.folds(rows: entries.count, previewing: ctx.previews(.kernel(role))),
			isExpanded: ctx.groupBinding(.group(title)),
			icon: {
				role == .kernel ? TreeIcon.tux : TreeIcon(symbol: MachmanSymbols.initramfs)
			},
			menu: {
				Button("Add from Disk…") {
					AddFlows.chooseKernelFile(
						viewModel: ctx.viewModel, vm: ctx.vm.name, role: role)
				}
				Button("Paste") { ctx.paste(into: .kernel(role)) }
					.disabled(!ctx.pasteboard.snapshot.canPaste(into: .kernel(role)))
			},
			accessory: {
				if role == .kernel && ctx.vm.kernelBootMissingKernel {
					TreeBadge.warning("No kernel selected — the VM cannot start")
				}
			}
		) {
			ForEach(entries) { file in
				let node: SidebarNode = role == .kernel ? .kernel(file.id) : .initramfs(file.id)
				HStack(spacing: 6) {
					role == .kernel ? TreeIcon.tux : TreeIcon(symbol: MachmanSymbols.initramfs)
					if ctx.renamingNode == node {
						RenameField(
							initial: ctx.renameDraft ?? file.label,
							problem: { ctx.renameProblem(node, $0) }
						) {
							ctx.commitRename(node, to: $0)
						} cancel: {
							ctx.endRename(node)
						}
					} else {
						Text(file.label)
							.fontWeight(file.active ? .medium : .regular)
							.truncationMode(.middle)
							.lineLimit(1)
							.help(file.id)
					}
					Spacer()
					if !file.owned {
						TreeBadge(
							symbol: MachmanSymbols.externalReference,
							help: "External file — promote to copy it into the VM")
					}
					if file.active {
						TreeBadge(
							symbol: MachmanSymbols.activeEntry, help: "Active", size: 10,
							style: theme.accentColor)
					}
				}
				.treeRow(
					node, opacity: file.active ? 1 : MachmanColors.inactiveEntryOpacity
				) { ctx.kernelEntryMenu(file, role: role) }
			}
			ctx.dropPreview(
				in: .kernel(role),
				icon: role == .kernel ? MachmanSymbols.kernelFile : MachmanSymbols.initramfs)
		}
		.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.kernel(role)))
	}
}
