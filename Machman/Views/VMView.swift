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
	@ObservedObject var vmController: VMController
	init(vmController: VMController) {
		self.vmController = vmController
	}

	var body: some View {
		if let vm = vmController.virtualMachine {
			VirtualMachineView(virtualMachine: vm)
			//	.onAppear { vmController.startVM() }
		} else {
			fatalError("No VM Configured")
		}
	}
}

#Preview {
}
