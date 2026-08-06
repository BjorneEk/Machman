//
//  MachmanApp.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//
//  App root: constructs the engine (VMRegistry) and hands the UI a MachmanControlling —
//  currently the in-process LocalMachman; phase 2 swaps in a RemoteMachman client here and
//  nothing below this file changes.
//

import SwiftUI
import Cocoa
import MachmanAPI

// machmanVMDir (the root directory for all VM data) lives in DataDir.swift.

@main
struct MachmanApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var viewModel: VMListViewModel
	@State var selection: String? = nil

	init() {
		let registry = VMRegistry()
		let viewModel = VMListViewModel(api: LocalMachman(registry: registry))
		_viewModel = StateObject(wrappedValue: viewModel)
	}

	var body: some Scene {
		WindowGroup {
			VMNavigationView(viewModel: viewModel, selection: $selection)
		}
		.commands {
			CommandGroup(before: .sidebar) {
				ForEach(viewModel.vms) { vm in
					Button(vm.name) {
						selection = vm.name
						viewModel.select(name: vm.name)
					}
					.help("show \(vm.name)")
				}
			}
			CommandMenu("Run") {
				ForEach(viewModel.vms) { vm in
					if !vm.state.isRunning {
						Button(action: {
							viewModel.startVM(vm.name)
							selection = vm.name
							viewModel.select(name: vm.name)
						}) {
							Label("\(vm.name)", systemImage: viewModel.runBtnLbl(vm: vm).rawValue)
						}
					}
				}
			}
			CommandMenu("Stop") {
				ForEach(viewModel.vms) { vm in
					if vm.state.isRunning {
						Button(action: {
							viewModel.stopVM(vm.name)
							selection = vm.name
							viewModel.select(name: vm.name)
						}) {
							Label("\(vm.name)", systemImage: viewModel.runBtnLbl(vm: vm).rawValue)
						}
					}
				}
			}
			CommandGroup(before: CommandGroupPlacement.newItem) {
				Button(action: {
					Task {
						if let name = await viewModel.createVM() {
							selection = name
							viewModel.select(name: name)
						}
					}
				}) {
					Label("New VM", systemImage: "plus")
				}
			}
		}
	}
}
class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
