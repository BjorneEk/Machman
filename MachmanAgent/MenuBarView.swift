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
import MachmanCore

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
				.disabled(!model.isEnabled(.start, vm))
				Button {
					model.start(vm, .headless)
				} label: {
					Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
				}
				.disabled(!model.isEnabled(.startHeadless, vm))
				Button {
					model.start(vm, .safe)
				} label: {
					Label("Start Safe", systemImage: MachmanSymbols.safe)
				}
				.disabled(!model.isEnabled(.startSafe, vm))
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
				// Also for a VM whose state is unknown or that stopped answering (V11): the
				// agent counts it as running when it quits, so its menu can stop it.
				Divider()
				Button {
					model.stop(vm.name, mode: .soft)
				} label: {
					Label("Shut Down", systemImage: MachmanSymbols.shutDown)
				}
				.disabled(!model.isEnabled(.shutDown, vm))
				Button {
					model.stop(vm.name, mode: .force)
				} label: {
					Label("Force Stop", systemImage: MachmanSymbols.forceStop)
				}
				.disabled(!model.isEnabled(.forceStop, vm))
			} label: {
				// Menu rendering may flatten StatusIcon's green to a template glyph — the
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
		// A lab run never launches another app: recorded, never performed.
		guard !MachmanTestMode.isActive else {
			MachmanLogger.log(.log, "test mode: would open the desktop app (\(suite))")
			return
		}
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
