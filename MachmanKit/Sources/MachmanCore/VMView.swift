//
//  ContentView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import SwiftUI
import Virtualization

struct VirtualMachineView: NSViewRepresentable {
	var virtualMachine: VZVirtualMachine
	var onCreate: ((VZVirtualMachineView) -> Void)? = nil

	func makeNSView(context: Context) -> VZVirtualMachineView {
		let view = VZVirtualMachineView()
		view.virtualMachine = virtualMachine
		if #available(macOS 14.0, *) {
			view.automaticallyReconfiguresDisplay = true
		}
		view.virtualMachine = virtualMachine
		DispatchQueue.main.async {
			onCreate?(view)
			view.window?.makeFirstResponder(view)

		}

		return view
	}

	func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {}
}

struct VMView: View {
	var vm: VZVirtualMachine
	init(vm: VZVirtualMachine) {
		self.vm = vm
	}

	var body: some View {
		VirtualMachineView(virtualMachine: vm)
	}
}

#Preview {
}
