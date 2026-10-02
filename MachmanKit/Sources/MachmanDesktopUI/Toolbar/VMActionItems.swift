//
//  VMActionItems.swift
//  MachmanDesktopUI
//
//  The toolbar's center action cluster (1.0.4 UI): the window toggle (omitted entirely for
//  VMs without an enabled display) and the start/safe ↔ shutdown/force control group with a
//  spinner during state transitions. Native controls only — see VMIndicator.swift.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

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
		.help(VMListViewModel.windowToggleHelp(vm))
	}

	private var policy: StartPolicy { vm.startPolicy ?? StartPolicy() }

	private func toggleWindow() {
		if vm.windowOpen {
			viewModel.closeWindow(vm.name)
		} else {
			viewModel.openWindow(vm.name)
		}
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
				// The click set pendingStarts synchronously; the state event is seconds out.
				if viewModel.isStartPending(vm.name) {
					transition(.starting)
				} else {
					ControlGroup {
						Button {
							viewModel.startPolicyDriven(vm)
						} label: {
							Image(systemName: MachmanSymbols.start)
						}
						.help(viewModel.startHelp(vm))
						Button {
							viewModel.startPolicyDriven(vm, .safe)
						} label: {
							SafeStartGlyph(size: 12)
						}
						.help("Start Safe — run on a discardable shadow")
					}
					.disabled(!viewModel.canStart(vm))
				}
			case .starting:
				transition(.starting)
			case .stopping:
				// A guest that ignores the shutdown request: Force Stop stays in reach (F3).
				// Immediate, like the running state's; only the ⌘. chords ask (P26).
				HStack(spacing: 4) {
					transition(.stopping)
					ControlGroup {
						Button {
							viewModel.stopVM(vm.name, mode: .force)
						} label: {
							Image(systemName: MachmanSymbols.forceStop)
						}
						.help("Force Stop")
						.accessibilityLabel("Force Stop")
					}
				}
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

	// The state's own progress word (H8), as the canvas shows it.
	private func transition(_ state: VMState) -> some View {
		HStack(spacing: 6) {
			ProgressView()
				.controlSize(.small)
			Text(state.progressLabel ?? state.displayLabel)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 6)
	}
}
