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

	// The sections show once kernel boot is (or was) configured (VMInfo.showsKernelSections:
	// parked, dimmed, while kernel boot is off); their rows are VMInfo.kernelTreeEntries.

	// The VM cannot start kernel boot without a kernel path.
	private var missingKernelWarning: Bool {
		ctx.vm.boot.mode == .linuxKernel && (ctx.vm.boot.kernel?.kernelPath ?? "").isEmpty
	}

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
			parked: ctx.vm.kernelSectionParked, isExpanded: ctx.groupBinding(.group(title)),
			icon: {
				if role == .kernel {
					TuxIcon(size: theme.metrics.iconSize + 1)
				} else {
					Image(systemName: MachmanSymbols.initramfs)
						.font(.system(size: theme.metrics.iconSize))
				}
			},
			menu: {
				Button("Add From Disk…") {
					AddFlows.chooseKernelFile(
						viewModel: ctx.viewModel, vm: ctx.vm.name, role: role)
				}
				Button("Paste") { ctx.paste(into: .kernel(role)) }
					.disabled(!ctx.pasteboard.snapshot.canPaste(into: .kernel(role)))
			},
			accessory: {
				if role == .kernel && missingKernelWarning {
					Image(systemName: MachmanSymbols.warning)
						.font(.system(size: 10))
						.foregroundStyle(MachmanColors.warning)
						.help("No kernel selected — the VM cannot start")
				}
			}
		) {
			ForEach(entries) { file in
				HStack(spacing: 6) {
					if role == .kernel {
						TuxIcon(size: theme.metrics.iconSize + 1)
					} else {
						Image(systemName: MachmanSymbols.initramfs)
							.font(.system(size: theme.metrics.iconSize))
					}
					if ctx.renamingNode == (role == .kernel
						? SidebarNode.kernel(file.id) : SidebarNode.initramfs(file.id)) {
						RenameField(initial: file.label) { tag in
							ctx.renamingNode = nil
							ctx.viewModel.renameKernelTag(ctx.vm.name, path: file.id, tag: tag)
						} cancel: {
							ctx.renamingNode = nil
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
						Image(systemName: MachmanSymbols.externalReference)
							.font(.system(size: 9))
							.foregroundStyle(.tertiary)
							.help("External file — promote to copy it into the VM")
					}
					if file.active {
						Image(systemName: MachmanSymbols.activeEntry)
							.font(.system(size: 10))
							.foregroundStyle(theme.accentColor)
							.help("Active")
					}
				}
				.treeRow(
					role == .kernel ? .kernel(file.id) : .initramfs(file.id),
					opacity: file.active ? 1 : MachmanColors.inactiveEntryOpacity
				) { ctx.kernelEntryMenu(file, role: role) }
			}
			ctx.dropPreview(
				in: .kernel(role),
				icon: role == .kernel ? MachmanSymbols.kernelFile : MachmanSymbols.initramfs)
		}
		.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.kernel(role)))
	}
}
