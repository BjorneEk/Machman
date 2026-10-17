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
			menu: { ctx.kernelGroupMenu(role: role) },
			accessory: {
				if role == .kernel && ctx.vm.kernelBootMissingKernel {
					TreeBadge.warning("No kernel selected — the VM cannot start")
				}
			}
		) {
			ForEach(entries) { file in
				let node: SidebarNode = role == .kernel ? .kernel(file.id) : .initramfs(file.id)
				// A macOS VM boots no kernel: none of its files reads as active (H55).
				let removeOnly = ctx.vm.kernelSectionsRemoveOnly
				let active = file.active && !removeOnly
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
							.fontWeight(active ? .medium : .regular)
							.truncationMode(.middle)
							.lineLimit(1)
							.help(file.id)
					}
					Spacer()
					// Promote isn't offered on a macOS VM (D31): its badge doesn't suggest it.
					if !file.owned {
						TreeBadge(
							symbol: MachmanSymbols.externalReference,
							help: removeOnly
								? "External file"
								: "External file — promote to copy it into the VM")
					}
					if active {
						TreeBadge(
							symbol: MachmanSymbols.activeEntry, help: "Active", size: 10,
							style: theme.accentColor)
					}
				}
				.treeRow(
					node, opacity: active || removeOnly ? 1 : MachmanColors.inactiveEntryOpacity
				) { ctx.kernelEntryMenu(file, role: role) }
			}
			ctx.dropPreview(
				in: .kernel(role),
				icon: role == .kernel ? MachmanSymbols.kernelFile : MachmanSymbols.initramfs)
		}
		// A macOS VM's sections take nothing new (D31).
		.onDrop(
			of: ctx.vm.kernelSectionsRemoveOnly ? [] : [.fileURL],
			delegate: ctx.dropDelegate(.kernel(role)))
	}
}

extension TreeContext {
	// A kernel group label's menu: its add paths, and on the parked Kernel label Remove Kernel
	// Settings… (H54, K2), which asks once and then removes the draft, the VM's kernel files
	// and their overrides in one step.
	@ViewBuilder
	func kernelGroupMenu(role: KernelRole) -> some View {
		if !vm.kernelSectionsRemoveOnly {
			Button("Add from Disk…") {
				AddFlows.chooseKernelFile(viewModel: viewModel, vm: vm.name, role: role)
			}
			Button("Paste") { paste(into: .kernel(role)) }
				.disabled(!pasteboard.snapshot.canPaste(into: .kernel(role)))
		}
		if role == .kernel && vm.offersKernelClear {
			if !vm.kernelSectionsRemoveOnly { Divider() }
			Button("Remove Kernel Settings…", role: .destructive) {
				viewModel.requestClearKernelSettings(vm)
			}
			.stopFirst(vm, .clearKernelSettings)
		}
	}
}
