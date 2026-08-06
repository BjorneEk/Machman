//
//  MenuBarView.swift
//  Machmand
//
//  The daemon's own control surface: every VM with its state and quick actions, driven by the
//  same MachmanControlling seam every other client uses (in-process here).
//

import SwiftUI
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
				case .installPhaseChanged, .log, .unknown:
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
				print("machmand: start \(name): \(error.localizedDescription)")
			}
		}
	}

	func stop(_ name: String, mode: StopMode) {
		Task {
			do {
				try await api.stop(vm: name, mode: mode)
			} catch {
				print("machmand: stop \(name): \(error.localizedDescription)")
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
				Button("Start") {
					model.start(vm.name)
				}
				.disabled(vm.state.isRunning)
				Button("Start Headless") {
					model.start(vm.name, headless: true)
				}
				.disabled(vm.state.isRunning)
				Divider()
				if vm.consoleOpen {
					Button("Close Window") {
						model.closeConsole(vm.name)
					}
					.disabled(!vm.state.isRunning)
				} else {
					Button("Open Window") {
						model.openConsole(vm.name)
					}
					.disabled(!vm.state.isRunning)
				}
				Divider()
				Button("Shut Down") {
					model.stop(vm.name, mode: .soft)
				}
				.disabled(!vm.state.isRunning)
				Button("Force Stop") {
					model.stop(vm.name, mode: .force)
				}
				.disabled(!vm.state.isRunning)
			} label: {
				Label(
					vm.name,
					systemImage: vm.state.isRunning ? "circle.fill" : "circle")
			}
		}
		if model.vms.isEmpty {
			Text("No VMs")
		}
		Divider()
		Text(MachmanPaths.dataDir())
			.font(.caption)
		Divider()
		Button("Quit Machmand") {
			NSApp.terminate(nil)
		}
	}
}
