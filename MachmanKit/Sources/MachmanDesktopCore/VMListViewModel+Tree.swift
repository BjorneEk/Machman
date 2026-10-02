//
//  VMListViewModel+Tree.swift
//  MachmanDesktopCore
//
//  The device tree's model side. Selecting a row and opening it are separate (T7): the
//  List's selection only selects — arrow keys, type-select and ⌘/⇧-clicks never open a tab
//  or connect a socket — and a plain click or Return opens the row through openTreeRow.
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
			guard let port = vm.allSerialPorts.first(where: { SerialPortRef($0) == ref }),
				port.unavailable == nil, port.enabled ?? true else { return nil }
			return revealTab(.terminal(ref), vm: vm.name)
		case .sshSession(let ref):
			// Rows exist only for OPEN sessions: this focuses wherever it lives.
			return revealTab(.ssh(ref), vm: vm.name)
		case .group, .disk, .mount, .device, .kernel, .initramfs:
			return nil
		}
	}
}
