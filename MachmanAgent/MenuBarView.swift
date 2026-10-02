//
//  MenuBarView.swift
//  MachmanAgent
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
	// Live macOS install phases by VM: an install's start emits no listChanged (P23).
	@Published private(set) var installPhases: [String: InstallPhase.Kind] = [:]
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
				case .installPhaseChanged(let name, let phase):
					// Progress ticks twice a second; only a new kind republishes.
					if self.installPhases[name] != phase.kind {
						self.installPhases[name] = phase.kind
					}
				case .log, .copyProgress, .operationChanged, .sshChanged, .setupChanged,
					.unknown:
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

	// Start waits for a running macOS install, as the desktop's does.
	func canStart(_ vm: VMInfo) -> Bool {
		!vm.state.isRunning && !vm.isInstallingMacOS(phase: installPhases[vm.name])
	}

	// The desktop's start rule (StartIntent): the policy, overridden only where named.
	func start(_ vm: VMInfo, _ intent: StartIntent) {
		let name = vm.name
		let options = vm.startOptions(intent)
		Task { await perform(.start(options), vm: name) }
	}

	func stop(_ name: String, mode: StopMode) {
		Task { await perform(.stop(mode), vm: name) }
	}

	func openWindow(_ name: String) {
		Task { await perform(.openWindow, vm: name) }
	}

	func closeWindow(_ name: String) {
		Task { await perform(.closeWindow, vm: name) }
	}

	// A failed action says so in an alert (P23); a MAC conflict offers Start Anyway, as the
	// desktop does, and a forced start that fails too just reports it.
	private func perform(_ action: MenuBarAction, vm name: String) async {
		do {
			switch action {
			case .start(let options): try await api.start(vm: name, options: options)
			case .stop(let mode): try await api.stop(vm: name, mode: mode)
			case .openWindow: try await api.openWindow(vm: name)
			case .closeWindow: try await api.closeWindow(vm: name)
			}
		} catch {
			let failure = MenuBarFailure(vm: name, action: action, error: error)
			// Logged first: the alert of an LSUIElement app can end up behind everything.
			MachmanLogger.log(.interactionError, "\(failure.title): \(failure.message)")
			if present(failure), let forced = failure.forceStart {
				await perform(.start(forced), vm: name)
			}
		}
	}

	// True when the user chose Start Anyway.
	private func present(_ failure: MenuBarFailure) -> Bool {
		NSApp.activate(ignoringOtherApps: true)
		let alert = NSAlert()
		alert.messageText = failure.title
		alert.informativeText = failure.message
		guard failure.forceStart != nil else {
			alert.runModal()
			return false
		}
		alert.addButton(withTitle: "Start Anyway")
		alert.addButton(withTitle: "Cancel")
		return alert.runModal() == .alertFirstButtonReturn
	}
}

struct MenuBarView: View {
	@ObservedObject var model: MenuBarModel

	var body: some View {
		ForEach(model.vms) { vm in
			Menu {
				// E22: an older vmhost still runs it, so its settings are locked until a restart.
				// A Text is a disabled menu row.
				if let reason = vm.restartToUpdate {
					Text(reason)
					Divider()
				}
				// Start follows the VM's start policy (window AND safety); Start Headless and
				// Start Safe override only what they name (decision 7).
				Button {
					model.start(vm, .plain)
				} label: {
					Label("Start", systemImage: MachmanSymbols.start)
				}
				.disabled(!model.canStart(vm))
				Button {
					model.start(vm, .headless)
				} label: {
					Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
				}
				.disabled(!model.canStart(vm))
				Button {
					model.start(vm, .safe)
				} label: {
					Label("Start Safe", systemImage: MachmanSymbols.safe)
				}
				.disabled(!model.canStart(vm))
				// A window item only while the VM runs with a display (P27).
				if let action = vm.windowAction {
					Divider()
					switch action {
					case .close:
						Button {
							model.closeWindow(vm.name)
						} label: {
							Label("Close Window", systemImage: MachmanSymbols.closeWindow)
						}
					case .open:
						Button {
							model.openWindow(vm.name)
						} label: {
							Label("Open Window", systemImage: MachmanSymbols.openWindow)
						}
					}
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
					StatusIcon(
						state: vm.state, windowOpen: vm.windowOpen,
						safeRun: vm.safeRun == true)
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
		Button("Quit Machman Agent") {
			NSApp.terminate(nil)
		}
	}

	private func openDesktop() {
		// The daemon's own suite id minus its `.agent` suffix IS the desktop's bundle id.
		let suite = MachmanPaths.suiteIdentifier()
		// Embedded daemon lives at <outer>.app/Contents/Library/LoginItems/MachmanAgent.app —
		// walk up to the outer bundle. A standalone scheme-run MachmanAgent.app walks to
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
