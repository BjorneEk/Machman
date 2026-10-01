//
//  StopFirst.swift
//  MachmanDesktopUI
//
//  The look of a stop-first action (P14, VMMenuRules): disabled with the reason as its
//  tooltip while the VM runs, never hidden. One modifier, so the tree, the picker and the
//  inspectors can't drift apart.
//

import SwiftUI
import MachmanAPI
import MachmanDesktopCore

extension View {
	func stopFirst(_ vm: VMInfo, _ action: StoppedOnly) -> some View {
		let reason = vm.refusal(action)
		return disabled(reason != nil).help(reason ?? "")
	}
}
