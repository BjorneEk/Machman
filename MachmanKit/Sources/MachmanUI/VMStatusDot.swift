//
//  VMStatusDot.swift
//  MachmanUI
//
//  A VM's state as the desktop shows it — the one place that knows a vmhost can stop
//  answering (E20). The daemon then serves the VM's last answer marked unresponsive, and
//  every state spot shows a hollow warning ring and "not responding" instead of the state.
//

import SwiftUI
import MachmanAPI

extension VMInfo {
	// The state word a state spot shows: "running", "stopped", … or "not responding".
	public var stateLabel: String {
		isUnresponsive ? "not responding" : String(describing: state)
	}
}

// StatusDot, or a hollow warning ring while the VM's vmhost does not answer: a shape no
// state dot has, so it reads without color, and no glow or pulse (nothing is happening).
public struct VMStatusDot: View {
	private let vm: VMInfo
	private let size: CGFloat

	public init(vm: VMInfo, size: CGFloat = 8) {
		self.vm = vm
		self.size = size
	}

	public var body: some View {
		if vm.isUnresponsive {
			Circle()
				.strokeBorder(MachmanColors.warning, lineWidth: max(1.5, size / 4))
				.frame(width: size, height: size)
				.accessibilityLabel(vm.stateLabel)
		} else {
			StatusDot(state: vm.state, size: size)
		}
	}
}

// Stands in for a VM row's subtitle while its vmhost does not answer.
public struct NotRespondingBadge: View {
	private let size: CGFloat

	public init(size: CGFloat = 9) {
		self.size = size
	}

	public var body: some View {
		HStack(spacing: 3) {
			Image(systemName: MachmanSymbols.warning)
			Text("Not responding")
		}
		.font(.system(size: size))
		.foregroundStyle(MachmanColors.warning)
		.help("Machman can't reach this VM's process right now")
	}
}
