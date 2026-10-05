//
//  VMListViewModel+Tree.swift
//  MachmanDesktopCore
//
//  The device tree's model side. Selecting a row and opening it are separate (T7): the
//  List's selection only selects — arrow keys, type-select and ⌘/⇧-clicks never open a tab
//  or connect a socket — and a plain click (treeRowClicked) or Return opens the row through
//  openTreeRow.
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMListViewModel {
	// The rows a click or Return opens: the VM root (its configuration tab), a serial port
	// (its terminal) and an open SSH session (its tab or window). Every other row only
	// selects; its inspector follows the selection.
	public static func opensOnClick(_ node: SidebarNode) -> Bool {
		switch node {
		case .vmRoot, .serial, .sshSession: return true
		case .group, .disk, .mount, .device, .kernel, .initramfs: return false
		}
	}

	// A plain click on a row that opens something: it selects the row, then opens it (T22).
	// Its selection never waits on the List, which doesn't see a click its row's own click
	// action takes — so an open console's row, the VM root with its configuration showing
	// and a host-gated port (whose inspector explains the gate) all select like any row.
	public func treeRowClicked(_ node: SidebarNode, vm: VMInfo) -> TornTab? {
		if treeSelection != [node] { treeSelection = [node] }
		return openTreeRow(node, vm: vm)
	}

	// The tree's List selection, mirrored. Never opens anything.
	public func treeSelectionChanged(_ selection: Set<SidebarNode>) {
		if treeSelection != selection { treeSelection = selection }
	}

	// Open what a row stands for. A disabled or host-gated port has no terminal and opens
	// nothing. A tab torn into its own window keeps its single mount: its payload comes
	// back for the caller to focus that window (openWindow is a view action).
	public func openTreeRow(_ node: SidebarNode, vm: VMInfo) -> TornTab? {
		switch node {
		case .vmRoot:
			return revealTab(.config, vm: vm.name)
		case .serial(let ref):
			guard let port = vm.port(for: ref), port.unavailable == nil, port.enabled ?? true
			else { return nil }
			return revealTab(.terminal(ref), vm: vm.name)
		case .sshSession(let ref):
			// Rows exist only for OPEN sessions: this focuses wherever it lives.
			return revealTab(.ssh(ref), vm: vm.name)
		case .group, .disk, .mount, .device, .kernel, .initramfs:
			return nil
		}
	}
}

// MARK: - Selection pruning (T15)

extension VMListViewModel {
	// The nodes of `selection` whose entity still exists on `vm` (visibility aside: a row
	// a filter hides keeps its selection). Groups stay while their section can show.
	public static func liveNodes(
		_ selection: Set<SidebarNode>, in vm: VMInfo, openSessions: [SSHSessionRef]
	) -> Set<SidebarNode> {
		selection.filter { node in
			switch node {
			case .vmRoot:
				return true
			case .group("SSH"):
				return vm.ssh?.configured == true
			case .group("Kernel"):
				return vm.showsKernelSections
			case .group("Serial"):
				return !vm.allSerialPorts.isEmpty
			case .group:
				return true
			case .disk(let id):
				return vm.disks.contains { $0.id == id }
			case .mount(let id):
				return vm.mounts.contains { $0.id == id }
			case .serial(let ref):
				return vm.port(for: ref) != nil
			case .device(let kind):
				return (vm.devices ?? []).contains { $0.kind == kind }
			case .kernel(let path):
				return vm.showsKernelSections
					&& vm.kernelTreeEntries(role: .kernel).contains { $0.id == path }
			case .initramfs(let path):
				return vm.showsKernelSections
					&& vm.kernelTreeEntries(role: .initramfs).contains { $0.id == path }
			case .sshSession(let ref):
				return openSessions.contains(ref)
			}
		}
	}

	// After a list refresh: drop the shown VM's selected nodes that went away. Runs inside
	// the store's willSet, so `vms` still holds the old list — which is how a rename is
	// told from a removal: one selected disk or kernel file whose id vanished while exactly
	// one id of its kind appeared moves the selection to it. renameDisk/renameKernelTag
	// repoint on their reply too, so whichever lands first wins and the other is a no-op.
	func pruneTreeSelection(incoming list: [VMInfo]) {
		guard !treeSelection.isEmpty, let name = selectedName,
			let new = list.first(where: { $0.name == name }) else { return }
		var pruned = Self.liveNodes(
			treeSelection, in: new, openSessions: openSSHSessions(vm: name))
		if pruned.isEmpty, treeSelection.count == 1, let gone = treeSelection.first,
			let old = vms.first(where: { $0.name == name }),
			let renamed = Self.renamedNode(gone, from: old, to: new) {
			pruned = [renamed]
		}
		if pruned != treeSelection { treeSelection = pruned }
	}

	private static func renamedNode(
		_ node: SidebarNode, from old: VMInfo, to new: VMInfo
	) -> SidebarNode? {
		func moved(_ id: String, _ before: [String], _ after: [String]) -> String? {
			let appeared = Set(after).subtracting(before)
			guard Set(before).subtracting(after) == [id], appeared.count == 1 else { return nil }
			return appeared.first
		}
		func paths(_ vm: VMInfo, _ role: KernelRole) -> [String] {
			vm.kernelTreeEntries(role: role).map(\.id)
		}
		switch node {
		case .disk(let id):
			return moved(id, old.disks.map(\.id), new.disks.map(\.id)).map { .disk($0) }
		case .kernel(let path):
			return moved(path, paths(old, .kernel), paths(new, .kernel)).map { .kernel($0) }
		case .initramfs(let path):
			return moved(path, paths(old, .initramfs), paths(new, .initramfs))
				.map { .initramfs($0) }
		default:
			return nil
		}
	}
}
