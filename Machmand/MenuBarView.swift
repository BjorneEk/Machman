//
//  MenuBarView.swift
//  Machmand
//
//  The daemon's own control surface: every VM with its state and quick actions, driven by the
//  same MachmanControlling seam every other client uses (in-process here).
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

@MainActor
final class MenuBarModel: ObservableObject {
	let api: MachmanControlling
	@Published private(set) var vms: [VMInfo] = []
	private var eventTask: Task<Void, Never>?

	init(api: MachmanControlling) {
		self.api = api
		eventTask = Task { [weak self] in
			guard let api = self?.api else { return }
			let stream = await api.events()
			await self?.reload()
			for await event in stream {
				guard let self = self else { return }
				switch event {
				case .stateChanged(let name, let state):
					if let index = self.vms.firstIndex(where: { $0.name == name }) {
						self.vms[index].state = state
					}
				case .listChanged:
					await self.reload()
				case .installPhaseChanged, .log, .copyProgress, .unknown:
					break
				}
			}
		}
	}

	deinit {
		eventTask?.cancel()
	}

	func reload() async {
		if let list = try? await api.listVMs() {
			vms = list
		}
	}

	func start(_ name: String, headless: Bool = false) {
		Task {
			do {
				try await api.start(vm: name, options: StartOptions(openConsole: !headless))
			} catch {
				MachmanLogger.log(.interactionError, "start \(name): \(error.localizedDescription)")
			}
		}
	}

	func stop(_ name: String, mode: StopMode) {
		Task {
			do {
				try await api.stop(vm: name, mode: mode)
			} catch {
				MachmanLogger.log(.interactionError, "stop \(name): \(error.localizedDescription)")
			}
		}
	}

	func openConsole(_ name: String) {
		Task {
			try? await api.openConsole(vm: name)
		}
	}

	func closeConsole(_ name: String) {
		Task {
			try? await api.closeConsole(vm: name)
		}
	}
}

struct MenuBarView: View {
	@ObservedObject var model: MenuBarModel

	var body: some View {
		ForEach(model.vms) { vm in
			Menu {
				Button {
					// Plain Start honors the VM's policy; "Start Headless" stays explicit.
					model.start(vm.name, headless: !(vm.startPolicy ?? StartPolicy()).windowed)
				} label: {
					Label("Start", systemImage: MachmanSymbols.start)
				}
				.disabled(vm.state.isRunning)
				Button {
					model.start(vm.name, headless: true)
				} label: {
					Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
				}
				.disabled(vm.state.isRunning)
				Divider()
				if vm.consoleOpen {
					Button {
						model.closeConsole(vm.name)
					} label: {
						Label("Close Window", systemImage: MachmanSymbols.closeWindow)
					}
					.disabled(!vm.state.isRunning)
				} else {
					Button {
						model.openConsole(vm.name)
					} label: {
						Label("Open Window", systemImage: MachmanSymbols.openWindow)
					}
					.disabled(!vm.state.isRunning)
				}
				Divider()
				Button {
					model.stop(vm.name, mode: .soft)
				} label: {
					Label("Shut Down", systemImage: MachmanSymbols.shutDown)
				}
				.disabled(!vm.state.isRunning)
				Button {
					model.stop(vm.name, mode: .force)
				} label: {
					Label("Force Stop", systemImage: MachmanSymbols.forceStop)
				}
				.disabled(!vm.state.isRunning)
			} label: {
				// Menu rendering may flatten StatusIcon's blue to a template glyph — the
				// window/terminal/pause shapes still differentiate the states.
				Label {
					Text(vm.name)
				} icon: {
					StatusIcon(state: vm.state, consoleOpen: vm.consoleOpen)
				}
			}
		}
		if model.vms.isEmpty {
			Text("No VMs")
		}
		Divider()
		Text(MachmanPaths.dataDir())
			.font(.caption)
		Divider()
		Button {
			openDesktop()
		} label: {
			Label("Open Machman", systemImage: MachmanSymbols.menuBarExtra)
		}
		Button("Quit Machmand") {
			NSApp.terminate(nil)
		}
	}

	private func openDesktop() {
		// The daemon's own suite id minus its `.agent` suffix IS the desktop's bundle id.
		let suite = MachmanPaths.suiteIdentifier()
		// Embedded daemon lives at <outer>.app/Contents/Library/LoginItems/Machmand.app —
		// walk up to the outer bundle. A standalone scheme-run Machmand.app walks to
		// nonsense; the id gate rejects that and Launch Services answers instead.
		let outer = Bundle.main.bundleURL
			.deletingLastPathComponent()   // …/LoginItems
			.deletingLastPathComponent()   // …/Library
			.deletingLastPathComponent()   // …/Contents
			.deletingLastPathComponent()   // <outer>.app
		if outer.pathExtension == "app", Bundle(url: outer)?.bundleIdentifier == suite {
			NSWorkspace.shared.openApplication(
				at: outer, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: suite) {
			NSWorkspace.shared.openApplication(
				at: url, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		MachmanLogger.log(.interactionError, "cannot find the Machman desktop app (\(suite))")
	}
}
