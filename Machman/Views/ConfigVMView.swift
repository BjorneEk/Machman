//
//  ConfigVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct ConfigVMView: View {
	@State private var vm: VirtualMachine
	private let viewModel: VMListViewModel?

	init(vm: VirtualMachine, viewModel: VMListViewModel? = nil) {
		self.vm = vm
		self.viewModel = viewModel
	}

	var body: some View {
		GroupBox {
			VStack {
				HardwareConfigView(vm: vm)
				BootConfigView(vm: vm, viewModel: viewModel)
					.id(vm.config.name)   // reset pane state (incl. install controller) per VM
				HistoryView(vm: vm)
				Spacer()
			}
		}
	}
}

#Preview {
}
