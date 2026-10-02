//
//  TreeMenus.swift
//  MachmanDesktopUI
//
//  The device tree's row context menus, one per row kind. A group label's menu (its add
//  actions) stays with the group in its section; the tree's background Paste is the shell's.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

extension TreeContext {
	@ViewBuilder
	func rootMenu() -> some View {
		// Stop-first actions show dimmed with the reason while the VM runs (P14).
		Button("Rename") { renamingRoot = true }
			.stopFirst(vm, .renameVM)
		// A copied entity (disk/kernel/mount from any VM) pastes first; plain file
		// URLs keep the Finder routing.
		Button("Paste") { pasteAnything() }
			.disabled(!pasteboard.snapshot.canPasteAnything)
		Divider()
		Button("Delete VM…", role: .destructive) { viewModel.deleteVM(vm) }
			.stopFirst(vm, .deleteVM)
	}

	// Batch actions lead a row's menu when it sits inside a multi-selection.
	@ViewBuilder
	func batchMenuItems(for node: SidebarNode) -> some View {
		if viewModel.treeSelection.count > 1, viewModel.treeSelection.contains(node) {
			let copyable = viewModel.copyableSelectionItems
			if !copyable.isEmpty {
				Button("Copy \(copyable.count) Items") {
					EntityClipboard.write(copyable)
				}
			}
			Button("Enable \(viewModel.treeSelection.count) Items") {
				viewModel.setSelectionEnabled(true, vm: vm)
			}
			Button("Disable \(viewModel.treeSelection.count) Items") {
				viewModel.setSelectionEnabled(false, vm: vm)
			}
			Divider()
		}
	}

	@ViewBuilder
	func diskMenu(_ disk: DiskInfo) -> some View {
		batchMenuItems(for: .disk(disk.id))
		if let path = disk.path {
			Button("Copy") {
				EntityClipboard.write(EntityClipboard(kind: .disk, path: path))
			}
			Button("Show in Finder") { Self.revealInFinder(path) }
			Divider()
		}
		Button(disk.isEnabled ? "Disable" : "Enable") {
			viewModel.setEnabled(vm.name, disks: [disk.id: !disk.isEnabled])
		}
		if disk.type == .storage && disk.owned != false {
			Button("Rename") { renamingNode = .disk(disk.id) }
				.stopFirst(vm, .renameDisk)
		}
		if disk.owned == false {
			Button("Promote to Owned") { viewModel.promoteDisk(vm.name, diskID: disk.id) }
				.stopFirst(vm, .promoteDisk)
		}
		Divider()
		// An owned disk's Delete… asks first; a reference detaches at once (H2: an ellipsis
		// promises a question).
		Button(disk.owned == true ? "Delete…" : "Remove", role: .destructive) {
			viewModel.requestRemoveDisk(vm.name, disk: disk)
		}
		.stopFirst(vm, .removeDisk)
	}

	@ViewBuilder
	func mountMenu(_ mount: MountInfo) -> some View {
		batchMenuItems(for: .mount(mount.id))
		Button("Copy") {
			EntityClipboard.write(EntityClipboard(
				kind: .mount, path: mount.path, tag: mount.tag))
		}
		Button("Show in Finder") { Self.revealInFinder(mount.path) }
		Divider()
		Button(mount.isEnabled ? "Disable" : "Enable") {
			viewModel.setEnabled(vm.name, mounts: [mount.id: !mount.isEnabled])
		}
		Divider()
		Button("Remove", role: .destructive) {
			viewModel.removeMount(vm.name, mountID: mount.id)
		}
	}

	// HIG: hide (don't dim) unavailable actions — a host-gated or disabled port has no
	// terminal and no socket.
	@ViewBuilder
	func serialMenu(
		_ port: SerialPortInfo, ref: SerialPortRef, open: Bool, gated: Bool, enabled: Bool
	) -> some View {
		batchMenuItems(for: .serial(ref))
		if !gated && enabled {
			if open {
				Button("Close Terminal (disconnect)") {
					viewModel.closeTab(.terminal(ref), vm: vm.name)
				}
			} else {
				Button("Open Terminal (connect)") { openTerminal(ref) }
			}
			if !isTorn(.terminal(ref)) {
				Button {
					detach(.terminal(ref))
				} label: {
					Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
				}
			}
			Button("Properties") {
				openTerminal(ref)
				viewModel.treeSelection = [.serial(ref)]   // the inspector follows selection
				viewModel.showInfoPanel = true
			}
			if let socket = port.socketPath {
				Button("Copy Socket Path") { Self.copyToPasteboard(socket) }
			}
			Divider()
		}
		Button(enabled ? "Disable" : "Enable") {
			let change = [String(port.index): !enabled]
			if port.kind == .console {
				viewModel.setEnabled(vm.name, console: change)
			} else {
				viewModel.setEnabled(vm.name, uart: change)
			}
		}
		// The remove APIs pop the highest index of a kind, so only that port offers Remove.
		if isLastOfKind(port) {
			Button("Remove", role: .destructive) {
				if port.kind == .console {
					viewModel.removeConsolePort(vm.name)
				} else {
					viewModel.removeUartPort(vm.name)
				}
			}
			.stopFirst(vm, .changeSerialPorts)
		}
	}

	private func isLastOfKind(_ port: SerialPortInfo) -> Bool {
		let peers = port.kind == .console ? (vm.consolePorts ?? []) : (vm.uartPorts ?? [])
		return port.index == peers.map(\.index).max()
	}

	@ViewBuilder
	func sshSessionMenu(_ ref: SSHSessionRef, torn: Bool) -> some View {
		if !torn {
			Button {
				detach(.ssh(ref))
			} label: {
				Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
			}
		}
		// Canvas tab or torn window alike: closeTab knows which.
		Button("Close Session") { viewModel.closeTab(.ssh(ref), vm: vm.name) }
	}

	@ViewBuilder
	func deviceMenu(_ device: DeviceInfo) -> some View {
		batchMenuItems(for: .device(device.kind))
		Button(device.enabled ? "Disable" : "Enable") {
			var updated = device
			updated.enabled = !device.enabled
			viewModel.updateDevice(vm.name, device: updated)
		}
		Button("Remove", role: .destructive) {
			viewModel.removeDevice(vm.name, kind: device.kind)
		}
	}

	@ViewBuilder
	func kernelEntryMenu(_ file: KernelTreeEntry, role: KernelRole) -> some View {
		if file.active {
			Button("Deselect") { setActiveKernelPath(nil, role: role) }
		} else {
			Button("Select") { setActiveKernelPath(file.id, role: role) }
		}
		Button("Copy") {
			EntityClipboard.write(EntityClipboard(
				kind: role == .kernel ? .kernel : .initramfs, path: file.id))
		}
		Button("Show in Finder") { Self.revealInFinder(file.id) }
		if file.owned {
			Button("Rename") {
				renamingNode = role == .kernel ? .kernel(file.id) : .initramfs(file.id)
			}
			.stopFirst(vm, .renameKernelFile)
		}
		if !file.owned {
			Button("Promote to Owned") {
				viewModel.promoteKernel(
					vm.name, role: role, sourcePath: file.id,
					tag: URL(fileURLWithPath: file.id)
						.deletingPathExtension().lastPathComponent)
			}
		}
		if file.owned {
			Divider()
			Button("Delete…", role: .destructive) {
				let fileName = (vm.boot.ownedKernels ?? [])
					.first(where: { $0.path == file.id })?.fileName
					?? (file.id as NSString).lastPathComponent
				viewModel.requestDeleteKernel(vm.name, path: file.id, fileName: fileName)
			}
		}
	}

	private func setActiveKernelPath(_ path: String?, role: KernelRole) {
		viewModel.setActiveKernelFile(vm, role: role, path: path)
	}

	private static func copyToPasteboard(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
		PasteboardWatch.general.refresh()
	}

	private static func revealInFinder(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}
