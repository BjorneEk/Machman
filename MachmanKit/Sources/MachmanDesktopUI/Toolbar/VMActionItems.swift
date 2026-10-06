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
		let help = VMListViewModel.windowToggleHelp(vm)
		Toggle(isOn: Binding(
			get: { vm.state == .running ? vm.windowOpen : policy.windowed },
			set: { _ in toggleWindow() })
		) {
			// Image-only in the bar; the title is what VoiceOver (H32) and the toolbar's
			// » menu (H33) read.
			Label(help, systemImage: MachmanSymbols.vmRunningWindowed)
				.labelStyle(.iconOnly)
		}
		.toggleStyle(.button)
		.disabled(vm.state != .running)
		.help(help)
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
			case .stopped, .error:
				// The click set pendingStarts synchronously; the state event is seconds out.
				if viewModel.isStartPending(vm.name) {
					transition(.starting)
				} else {
					// Titled, the group reads by its first action in the toolbar's » menu (H33).
					ControlGroup(viewModel.startHelp(vm)) {
						Button {
							viewModel.startPolicyDriven(vm)
						} label: {
							Self.icon(viewModel.startHelp(vm), MachmanSymbols.start)
						}
						.help(viewModel.startHelp(vm))
						Button {
							viewModel.startPolicyDriven(vm, .safe)
						} label: {
							Label {
								Text(Self.startSafe)
							} icon: {
								SafeStartGlyph(size: 12)
							}
							.labelStyle(.iconOnly)
						}
						.help(Self.startSafe)
					}
					.disabled(!viewModel.canStart(vm))
				}
			case .starting:
				transition(.starting)
			case .unknown:
				// Machman Agent hasn't reached the VM's vmhost (P37): it may well be running,
				// so no Start — the spinner says it is being reached. Force Stop stays in
				// reach, as while stopping: the way out of a vmhost that never answers (C15).
				HStack(spacing: 4) {
					transition(.unknown)
						.help(VMInfo.unreachedHelp)
					forceStop
				}
			case .stopping:
				// A guest that ignores the shutdown request: Force Stop stays in reach (F3).
				// Immediate, like the running state's; only the ⌘. chords ask (P26).
				HStack(spacing: 4) {
					transition(.stopping)
					forceStop
				}
			case .running, .paused:
				ControlGroup("Shut Down") {
					Button {
						viewModel.stopVM(vm.name, mode: .soft)
					} label: {
						Self.icon("Shut Down", MachmanSymbols.shutDown)
					}
					.help("Shut Down")
					Button {
						viewModel.stopVM(vm.name, mode: .force)
					} label: {
						Self.icon("Force Stop", MachmanSymbols.forceStop)
					}
					.help("Force Stop")
				}
			}
		}
		.animation(.snappy(duration: 0.25), value: vm.state)
	}

	// Force Stop on its own, beside a transition's spinner.
	private var forceStop: some View {
		ControlGroup("Force Stop") {
			Button {
				viewModel.stopVM(vm.name, mode: .force)
			} label: {
				Self.icon("Force Stop", MachmanSymbols.forceStop)
			}
			.help("Force Stop")
		}
	}

	private static let startSafe = "Start Safe — run on a discardable shadow"


	// An image-only toolbar button's label: titled, so VoiceOver (H32) and the toolbar's »
	// menu (H33) read its name; the bar shows the icon.
	private static func icon(_ title: String, _ symbol: String) -> some View {
		Label(title, systemImage: symbol)
			.labelStyle(.iconOnly)
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
