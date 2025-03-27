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

	func makeNSView(context: Context) -> VZVirtualMachineView {
		let vmView = VZVirtualMachineView(frame: .zero)
		if #available(macOS 14.0, *) {
			vmView.automaticallyReconfiguresDisplay = true
		}
		vmView.virtualMachine = virtualMachine
		DispatchQueue.main.async {
			vmView.window?.makeFirstResponder(vmView)
		}
		return vmView
	}

	func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
		// Update the view if needed.
	}
}

struct VMView: View {
	@ObservedObject var vmController: VMController

	init(vmController: VMController) {
		self.vmController = vmController
	}

	var body: some View {
		if let vm = vmController.virtualMachine {
			VirtualMachineView(virtualMachine: vm).onAppear {
				vmController.startVM()
			}
		} else {
			fatalError("No VM Configured")
		}
	}
}

#Preview {
}
