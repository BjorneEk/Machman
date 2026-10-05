//
//  SafeSaveSheet.swift
//  MachmanDesktopUI
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

	// `name` pre-fills the field (render scenes); the default is "<vm> saved".
	init(vm: VMInfo, viewModel: VMListViewModel, name: String? = nil) {
		self.vm = vm
		self.viewModel = viewModel
		_newName = State(initialValue: name ?? viewModel.defaultSafeSaveName(for: vm.name))
	}

	private var problem: String? { viewModel.newVMNameProblem(newName) }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label("Save “\(vm.name)” as a New VM", systemImage: MachmanSymbols.safe)
				.font(.headline)
			// True with or without unshadowed disks: those move to the new VM (C5).
			Text("The safe run carries on as the new VM, and the disks it wrote directly move "
				+ "into it while the original keeps using them.")
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			TextField("New VM name", text: $newName)
				.textFieldStyle(.roundedBorder)
			if let problem {
				FieldProblem(problem)
			}
			HStack {
				if viewModel.safeSaveInFlight {
					ProgressView()
						.controlSize(.small)
				}
				Spacer()
				// Esc cancels — and stays inert while the save is in flight.
				Button("Cancel") {
					viewModel.safeSaveRequest = nil
				}
				.keyboardShortcut(.cancelAction)
				.disabled(viewModel.safeSaveInFlight)
				Button("Save") {
					viewModel.submitSafeSave(vm, name: newName)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(viewModel.safeSaveInFlight || problem != nil)
				.help("The new VM gets a fresh MAC address on its next boot")
			}
		}
		.padding(20)
		.frame(width: 400)
	}
}
