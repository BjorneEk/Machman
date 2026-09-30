//
//  SafeSaveSheet.swift
//  MachmanDesktop
//
//  The vm.safeSave name prompt: promote a running safe-run copy into its own VM. Presented
//  via .sheet(item: $viewModel.safeSaveRequest), the CopyVMSheet pattern.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct SafeSaveSheet: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var newName: String

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_newName = State(initialValue: viewModel.defaultSafeSaveName(for: vm.name))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Save \(vm.name)'s safe run as a new VM", systemImage: MachmanSymbols.safe)
				.font(.headline)
			Text("The running copy becomes its own VM without interrupting it — "
				+ "\(vm.name) stays untouched and shows as stopped. The new VM gets a "
				+ "fresh MAC address on its next boot.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			TextField("New VM name", text: $newName)
				.textFieldStyle(.roundedBorder)
			HStack {
				if viewModel.safeSaveInFlight {
					ProgressView()
						.controlSize(.small)
				}
				Spacer()
				Button("Cancel") {
					viewModel.safeSaveRequest = nil
				}
				.disabled(viewModel.safeSaveInFlight)
				Button("Save") {
					viewModel.safeSave(vm.name, to: newName)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(viewModel.safeSaveInFlight || newName.isEmpty
					|| viewModel.hasVM(newName))
			}
		}
		.padding(20)
		.frame(width: 400)
	}
}

#Preview {
}
