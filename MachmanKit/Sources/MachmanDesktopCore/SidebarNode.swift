//
//  SidebarNode.swift
//  MachmanDesktopCore
//
//  The sidebar device tree's row identities: the tree's selection, the inspector's target and
//  the tab ↔ row funnel (VMListViewModel.tabClosed) all speak in these.
//

import MachmanAPI
import MachmanUI

// Stable identity for every selectable row in the tree (multi-select + context menus).
public enum SidebarNode: Hashable {
	case vmRoot
	case group(String)
	case disk(String)            // DiskInfo.id
	case mount(String)           // MountInfo.id
	case serial(SerialPortRef)
	case device(DeviceKind)
	case kernel(String)          // OwnedKernelFile.id (path)
	case initramfs(String)
	case sshSession(SSHSessionRef)   // an OPEN ephemeral session tab (no device behind it)
}
