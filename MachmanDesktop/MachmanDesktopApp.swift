//
//  MachmanDesktopApp.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-03-27.
//
//  MachmanDesktop is a pure client: it renders and commands VMs that live in the MachmanAgent
//  daemon, over the socket. No Virtualization framework, no engine, no entitlements — if the
//  daemon is away, the app shows a connect screen and can launch it.
//

import SwiftUI
import MachmanUI
import Cocoa
import MachmanAPI

@main
struct MachmanDesktopApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var connection: DaemonConnection
	@State var selection: String? = nil

	init() {
		_connection = StateObject(wrappedValue: DaemonConnection())
	}

	var body: some Scene {
		WindowGroup {
			if let viewModel = connection.viewModel {
				VMNavigationView(viewModel: viewModel, selection: $selection)
					.id(ObjectIdentifier(viewModel))   // remount per (re)connection
			} else {
				ConnectingView(connection: connection)
			}
		}
		.commands {
			CommandGroup(before: .sidebar) {
				if let viewModel = connection.viewModel {
					ForEach(viewModel.vms) { vm in
						Button(vm.name) {
							selection = vm.name
							viewModel.select(name: vm.name)
						}
						.help("show \(vm.name)")
						// The applicable console-window action rides right under its VM.
						if vm.state.isRunning {
							if vm.consoleOpen {
								Button(action: {
									viewModel.closeConsole(vm.name)
								}) {
									Label("Close \(vm.name) Window",
										systemImage: MachmanSymbols.closeWindow)
								}
							} else {
								Button(action: {
									viewModel.openConsole(vm.name)
									selection = vm.name
									viewModel.select(name: vm.name)
								}) {
									Label("Open \(vm.name) Window",
										systemImage: MachmanSymbols.openWindow)
								}
							}
						}
					}
				}
			}
			CommandMenu("Run") {
				if let viewModel = connection.viewModel {
					ForEach(viewModel.vms) { vm in
						Menu(vm.name) {
							Button(action: {
								viewModel.startVM(vm.name)
								selection = vm.name
								viewModel.select(name: vm.name)
							}) {
								Label("Start", systemImage: MachmanSymbols.start)
							}
							.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
							Button(action: {
								viewModel.startVM(vm.name, headless: true)
								selection = vm.name
								viewModel.select(name: vm.name)
							}) {
								Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
							}
							.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
						}
					}
				}
			}
			CommandMenu("Stop") {
				if let viewModel = connection.viewModel {
					ForEach(viewModel.vms) { vm in
						Menu(vm.name) {
							Button(action: {
								viewModel.stopVM(vm.name, mode: .soft)
								selection = vm.name
								viewModel.select(name: vm.name)
							}) {
								Label("Shut Down", systemImage: MachmanSymbols.shutDown)
							}
							.disabled(!vm.state.isRunning)
							Button(action: {
								viewModel.stopVM(vm.name, mode: .force)
								selection = vm.name
								viewModel.select(name: vm.name)
							}) {
								Label("Force Stop", systemImage: MachmanSymbols.forceStop)
							}
							.disabled(!vm.state.isRunning)
						}
					}
				}
			}
			CommandGroup(before: CommandGroupPlacement.newItem) {
				if let viewModel = connection.viewModel {
					Button(action: {
						Task {
							if let name = await viewModel.createVM() {
								selection = name
								viewModel.select(name: name)
							}
						}
					}) {
						Label("New VM", systemImage: MachmanSymbols.add)
					}
					Button(action: {
						if let vm = viewModel.selected {
							viewModel.requestCopy(vm)
						}
					}) {
						Label("Duplicate…", systemImage: MachmanSymbols.duplicateVM)
					}
					.keyboardShortcut("d")
					.disabled(viewModel.selected == nil
						|| viewModel.selected?.state.isRunning == true
						|| viewModel.copyInFlight)
				}
			}
		}
	}
}

class AppDelegate: NSObject, NSApplicationDelegate {
	// A pure manager: VMs live in MachmanAgent and are unaffected by this app quitting.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
