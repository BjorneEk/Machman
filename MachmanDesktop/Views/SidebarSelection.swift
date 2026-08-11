//
//  SidebarSelection.swift
//  MachmanDesktop
//
//  What the sidebar tree can select: a VM (its config pane) or one of its serial ports (that
//  port's detail pane). The category nodes (Console/UART) are expand-only and never selected.
//

import MachmanAPI

enum SidebarSelection: Hashable {
	case vm(String)
	case serial(vm: String, kind: SerialPortKind, index: Int)

	var vmName: String {
		switch self {
		case .vm(let name): return name
		case .serial(let name, _, _): return name
		}
	}
}
