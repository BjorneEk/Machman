//
//  ConfigVMSerialPortsView.swift
//  MachmanDesktop
//
//  Serial-port counts, styled like the CPU control: how many console (virtio, guest /dev/hvcN)
//  and uart (PL011, guest /dev/ttyAMAN) ports the VM has. Ports are fixed at VM start, so the
//  steppers are disabled while it runs. console + uart share a 10-port budget, so each stepper's
//  range shrinks by the other's count — the +/- buttons disable themselves at the bounds.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct ConfigVMSerialPortsView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	private static let maxTotal = 10
	private var consoleCount: Int { vm.consolePorts?.count ?? 0 }
	private var uartCount: Int { vm.uartPorts?.count ?? 0 }
	private var running: Bool { vm.state.isRunning }

	var body: some View {
		GroupBox {
			HStack {
				stepper(
					count: consoleCount, other: uartCount, symbol: MachmanSymbols.serialConsole,
					label: "Consoles",
					tooltip: running
						? "Stop the VM to change its serial ports"
						: "Virtio console ports — guest /dev/hvcN (needs a virtio driver)",
					add: { viewModel.addConsolePort(vm.name) },
					remove: { viewModel.removeConsolePort(vm.name) })
				Divider().frame(height: 26)
				stepper(
					count: uartCount, other: consoleCount, symbol: MachmanSymbols.serialUart,
					label: "UARTs",
					tooltip: running
						? "Stop the VM to change its serial ports"
						: "PL011 UART ports — guest /dev/ttyAMAN (bare-metal friendly)",
					add: { viewModel.addUartPort(vm.name) },
					remove: { viewModel.removeUartPort(vm.name) })
				Spacer()
			}
			.padding(2)
		}
		.padding(2)
	}

	@ViewBuilder
	private func stepper(
		count: Int, other: Int, symbol: String, label: String, tooltip: String,
		add: @escaping () -> Void, remove: @escaping () -> Void
	) -> some View {
		Stepper(
			value: Binding(
				get: { count },
				set: { newValue in
					if newValue > count { add() } else if newValue < count { remove() }
				}),
			in: 0...(Self.maxTotal - other)
		) {
			HStack(spacing: 4) {
				Text("\(count)").fontWeight(.bold).font(.title2)
				Image(systemName: symbol).fontWeight(.bold).font(.title2)
				Text(label).fontWeight(.bold).font(.title2)
			}
		}
		.disabled(running)
		.help(tooltip)
	}
}

#Preview {
}
