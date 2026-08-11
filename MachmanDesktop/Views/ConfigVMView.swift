//
//  ConfigVMView.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI
import MachmanAPI

struct ConfigVMView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	var body: some View {
		GroupBox {
			// Scrolls when the window is too short instead of overflowing — so this column and
			// the mounts column (whose Table already scrolls) shrink together and their bottom
			// edges stay aligned.
			ScrollView {
				VStack {
					HardwareConfigView(vm: vm, viewModel: viewModel)
					ConfigVMSerialPortsView(vm: vm, viewModel: viewModel)
					RunDefaultsView(vm: vm, viewModel: viewModel)
					BootConfigView(vm: vm, viewModel: viewModel)
						.id(vm.name)   // reset pane state per VM
					HistoryView(vm: vm)
				}
			}
		}
	}
}

#Preview {
}
