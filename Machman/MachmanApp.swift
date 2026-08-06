//
//  MachmanApp.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import SwiftUI
import Cocoa

// machmanVMDir (the root directory for all VM data) lives in DataDir.swift.

@main
struct MachmanApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var viewModel = VMListViewModel()
	@State var selection: VirtualMachine? = nil
	var body: some Scene {
		WindowGroup {
			VMNavigationView(viewModel: viewModel, selection: $selection)
		}
		.commands {
			CommandGroup(before: .sidebar) {
				ForEach(viewModel.vmList(), id: \.id) { vm in
					Button(vm.config.name) {
						selection = vm
						viewModel.select(vm: selection)
					}
					.help("show \(vm.config.name)")
				}
			}
			CommandMenu("Run") {
				ForEach(viewModel.vmList(), id: \.id) { vm in
					if !viewModel.runBtnLbl(vm: vm).running() {
						Button(action: {
							viewModel.run(c: vm.config)
							selection = vm
							viewModel.select(vm: selection)
						}) {
							Label("\(vm.config.name)", systemImage: viewModel.runBtnLbl(vm: vm).rawValue)
						}
					}
				}
			}
			CommandMenu("Stop") {
				ForEach(viewModel.vmList(), id: \.id) { vm in
					if viewModel.runBtnLbl(vm: vm).running() {
						Button(action: {
							viewModel.run(c: vm.config)
							selection = vm
							viewModel.select(vm: selection)
						}) {
							Label("\(vm.config.name)", systemImage: viewModel.runBtnLbl(vm: vm).rawValue)
						}
					}
				}
			}
			CommandGroup(before: CommandGroupPlacement.newItem) {
				Button(action: {
					selection = viewModel.addNewVM()
					viewModel.select(vm: selection)
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
