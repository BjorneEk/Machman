//
//  VMListViewModel+Start.swift
//  MachmanDesktopCore
//
//  The one way the desktop starts a VM (decision 7, P21): every affordance — the toolbar,
//  the picker row, the Run menu, the Dock — passes a StartIntent through
//  startPolicyDriven, which turns the VM's start policy into options (StartIntent.swift)
//  and refuses while the VM runs, installs or already has a start in flight.
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMListViewModel {
	// A plain Start follows the policy; .headless and .safe override only what they name.
	public func startPolicyDriven(_ vm: VMInfo, _ intent: StartIntent = .plain) {
		guard canStart(vm) else { return }
		let options = vm.startOptions(intent)
		startVM(vm.name, headless: !options.openWindow, safe: options.safe)
	}

	// A start already sent but not yet visible in vm.state counts like running; a macOS
	// install holds the VM until it finishes.
	public func canStart(_ vm: VMInfo) -> Bool {
		!vm.state.isRunning && !isInstalling(vm) && !isStartPending(vm.name)
	}

	// MARK: - Dock menu

	// One Dock item per VM: Shut Down while it runs, Start otherwise. The list is the
	// app-scoped store's, so it shows while reconnecting — with every item disabled until a
	// view model can act on it.
	public struct DockMenuItem: Equatable, Sendable {
		public let vm: String
		public let title: String
		public let running: Bool
		public let enabled: Bool
	}

	public static func dockMenuItems(
		vms: [VMInfo], viewModel: VMListViewModel?
	) -> [DockMenuItem] {
		vms.map { vm in
			let running = vm.state.isRunning
			return DockMenuItem(
				vm: vm.name,
				title: running ? "Shut Down \(vm.name)" : "Start \(vm.name)",
				running: running,
				enabled: viewModel.map { running || $0.canStart(vm) } ?? false)
		}
	}

	// Read at click time: the menu was built from a list that may have moved since.
	public func performDockItem(vm name: String) {
		guard let vm = vms.first(where: { $0.name == name }) else { return }
		if vm.state.isRunning {
			stopVM(name, mode: .soft)
		} else {
			startPolicyDriven(vm)
		}
	}
}
