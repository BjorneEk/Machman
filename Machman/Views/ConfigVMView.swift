//
//  ConfigVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-04-03.
//

import SwiftUI

struct ConfigVMView: View {
	@State private var vm: VirtualMachine

	init(vm: VirtualMachine) {
		self.vm = vm
	}

	var body: some View {
		GroupBox {
			VStack {
				HardwareConfigView(vm: vm)
				BootConfigView(vm: vm)
				HistoryView(vm: vm)
				Spacer()
			}
		}
	}
}

#Preview {
}
