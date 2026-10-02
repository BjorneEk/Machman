//
//  VMView.swift
//  MachmanCore
//
//  Created by Gustaf Franzen on 2025-03-27.
//
//  A running VM's display in its vmhost window (WindowPresenter): VZVirtualMachineView with
//  the key-capture toast over it.
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
	var onCreate: ((VZVirtualMachineView) -> Void)?
	var captureStatus: KeyCaptureStatus?
	init(
		vm: VZVirtualMachine, onCreate: ((VZVirtualMachineView) -> Void)? = nil,
		captureStatus: KeyCaptureStatus? = nil
	) {
		self.vm = vm
		self.onCreate = onCreate
		self.captureStatus = captureStatus
	}

	var body: some View {
		VirtualMachineView(virtualMachine: vm, onCreate: onCreate)
			.overlay(alignment: .top) {
				if let captureStatus {
					KeyCaptureToast(status: captureStatus)
				}
			}
	}
}
