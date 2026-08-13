//
//  VMActionItems.swift
//  MachmanDesktop
//
//  The toolbar's center action cluster (1.0.4 UI): the window toggle (omitted entirely for
//  VMs without an enabled display) and the start/safe ↔ shutdown/force control group with a
//  spinner during state transitions. Native controls only — see VMIndicator.swift.
//

import SwiftUI
import MachmanUI
import MachmanAPI

// Native toggle-style button. While the VM is down it shows (and locks to) the default
// start mode; while running it opens/closes the VM window.
struct WindowToggleItem: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Toggle(isOn: Binding(
			get: { vm.state == .running ? vm.windowOpen : policy.windowed },
			set: { _ in toggleWindow() })
		) {
			Image(systemName: MachmanSymbols.vmRunningWindowed)
		}
		.toggleStyle(.button)
		.disabled(vm.state != .running)
		.help(tooltip)
	}

	private var policy: StartPolicy { vm.startPolicy ?? StartPolicy() }

	private func toggleWindow() {
		if vm.windowOpen {
			viewModel.closeWindow(vm.name)
		} else {
			viewModel.openWindow(vm.name)
		}
	}

	private var tooltip: String {
		if vm.state != .running {
			return "Window opens on start (default: \(policy.windowed ? "on" : "off"))"
		}
		return vm.windowOpen ? "Close the VM window (keeps running)" : "Open the VM window"
	}
}

// Start/StartSafe ↔ ShutDown/ForceStop as one native control group; spinner during
// transitions. The plain Start follows the VM's start policy (window mode AND safety);
// Start Safe keeps the policy's window mode but forces safety on.
struct StartStopGroup: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Group {
			switch vm.state {
			case .stopped, .error, .unknown:
				ControlGroup {
					Button {
						viewModel.startPolicyDriven(vm)
					} label: {
						Image(systemName: MachmanSymbols.start)
					}
					.help(startHelp)
					Button {
						viewModel.startPolicyDriven(vm, safeOverride: true)
					} label: {
						SafeStartGlyph(size: 12)
					}
					.help("Start Safe — run on a discardable shadow")
				}
				.disabled(viewModel.isInstalling(vm))
			case .starting:
				transition("Starting…")
			case .stopping:
				transition("Stopping…")
			case .running, .paused:
				ControlGroup {
					Button {
						viewModel.stopVM(vm.name, mode: .soft)
					} label: {
						Image(systemName: MachmanSymbols.shutDown)
					}
					.help("Shut Down")
					Button {
						viewModel.stopVM(vm.name, mode: .force)
					} label: {
						Image(systemName: MachmanSymbols.forceStop)
					}
					.help("Force Stop")
				}
			}
		}
		.animation(.snappy(duration: 0.25), value: vm.state)
	}

	private var startHelp: String {
		if viewModel.isInstalling(vm) { return "macOS is installing; wait for it to finish" }
		let policy = vm.startPolicy ?? StartPolicy()
		return "Start" + (policy.windowed ? "" : " (headless)") + (policy.safe ? " (safe)" : "")
	}

	private func transition(_ label: String) -> some View {
		HStack(spacing: 6) {
			ProgressView()
				.controlSize(.small)
			Text(label)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 6)
	}
}
