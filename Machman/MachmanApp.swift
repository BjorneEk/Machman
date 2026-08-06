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
import MachmanCore

@main
struct MachmanApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var viewModel: VMListViewModel
	@State var selection: String? = nil

	init() {
		_viewModel = StateObject(wrappedValue: VMListViewModel(api: EngineHolder.api))
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
// The one engine instance for this process. SwiftUI may re-run App.init, so the engine lives
// here rather than in the App struct; the app delegate also reaches it for quit handling.
// Dies with the daemon split (Machmand owns the engine and quit semantics from phase 2 on).
@MainActor
enum EngineHolder {
	static let registry = VMRegistry()
	static let api = LocalMachman(registry: registry)
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	// VMs can now outlive their console windows, so closing the last window must not kill
	// the app (and with it, every running VM).
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		let registry = EngineHolder.registry
		let running = registry.list().filter { $0.state.isRunning }
		guard !running.isEmpty else { return .terminateNow }

		let alert = NSAlert()
		alert.messageText = running.count == 1
			? "\(running[0].name) is still running"
			: "\(running.count) VMs are still running"
		alert.informativeText = "Quitting stops every running VM "
			+ "(they live in this app until the daemon split)."
		alert.addButton(withTitle: "Stop All & Quit")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else {
			return .terminateCancel
		}
		Task { @MainActor in
			for vm in running {
				try? await registry.stop(vm, mode: .force)
			}
			sender.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}
}
