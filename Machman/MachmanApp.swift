//
//  MachmanApp.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-27.
//

import SwiftUI
import Cocoa

let machmanVMDir: String = NSHomeDirectory() + "/.machman"


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
					}
					.help("show \(vm.config.name)")
				}
			}
			CommandMenu("Run") {
				ForEach(viewModel.vmList(), id: \.id) { vm in
					if !viewModel.runBtnLbl(c: vm.config).running() {
						Button(action: {
							viewModel.run(c: vm.config)
							selection = vm
						}) {
							Label("\(vm.config.name)", systemImage: viewModel.runBtnLbl(c: vm.config).rawValue)
						}
					}
				}
			}
			CommandMenu("Stop") {
				ForEach(viewModel.vmList(), id: \.id) { vm in
					if viewModel.runBtnLbl(c: vm.config).running() {
						Button(action: {
							viewModel.run(c: vm.config)
							selection = vm
						}) {
							Label("\(vm.config.name)", systemImage: viewModel.runBtnLbl(c: vm.config).rawValue)
						}
					}
				}
			}
			CommandGroup(before: CommandGroupPlacement.newItem) {
				Button(action: {
					selection = viewModel.addNewVM()
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
