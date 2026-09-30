//
//  TornTab.swift
//  MachmanUI
//
//  What a torn-off window shows (1.0.4 UI): one VM's config tab or one of its terminals. The
//  payload is Codable, so torn windows restore across app relaunches. The staleness rule is
//  pure value logic (the window bookkeeping and dismissal stay in the desktop target).
//

import Foundation
import MachmanAPI

public struct TornTab: Codable, Hashable {
	public var vm: String
	public var tab: VMPaneTab

	public init(vm: String, tab: VMPaneTab) {
		self.vm = vm
		self.tab = tab
	}
}

extension TornTab {
	// The list-refresh reconcile rule, mirroring the canvas's: a VM that left the list takes
	// all its tabs with it; a terminal whose port left the VM goes too. SSH sessions are
	// local processes (nothing in the list backs them) and config follows the VM — for both,
	// only the VM vanishing invalidates the tab.
	public func isStale(in list: [VMInfo]) -> Bool {
		guard let vm = list.first(where: { $0.name == self.vm }) else { return true }
		guard case .terminal(let ref) = tab else { return false }
		let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
		return !ports.contains { SerialPortRef($0) == ref }
	}
}
