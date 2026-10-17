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

// A shutdown the Stop menu's chords ask about (P26): ⌘. is the system cancel chord, and
// from a focused terminal it reaches the menu. One sentence each (decision 16).
public struct PendingStop: Identifiable, Equatable {
	public let id = UUID()
	public let vm: String
	public let mode: StopMode

	public init(vm: String, mode: StopMode) {
		self.vm = vm
		self.mode = mode
	}

	public var title: String {
		switch mode {
		case .soft: return "Shut down \u{201C}\(vm)\u{201D}?"
		case .force: return "Force stop \u{201C}\(vm)\u{201D}?"
		}
	}

	public var message: String {
		switch mode {
		case .soft: return "\(vm)’s guest is asked to shut down."
		case .force: return "\(vm) stops at once, like pulling its power cord."
		}
	}

	public var confirmLabel: String {
		switch mode {
		case .soft: return "Shut Down"
		case .force: return "Force Stop"
		}
	}
}

extension VMListViewModel {
	// A plain Start follows the policy; .headless and .safe override only what they name.
	public func startPolicyDriven(_ vm: VMInfo, _ intent: StartIntent = .plain) {
		guard canStart(vm) else { return }
		let options = vm.startOptions(intent)
		startVM(vm.name, headless: !options.openWindow, safe: options.safe)
	}

	// A start already sent but not yet visible in vm.state counts like running, and so does
	// a VM whose state is unknown or that stopped answering (P37, VMBusyRule); a macOS
	// install holds the VM until it finishes.
	public func canStart(_ vm: VMInfo) -> Bool {
		!vm.mayBeRunning && !isInstalling(vm) && !isStartPending(vm.name)
	}

	// MARK: - Stop

	// The Stop menu's chords ask before stopping; the toolbar, the picker, the Dock and the
	// per-VM submenus stay immediate.
	public func requestStop(_ vm: VMInfo, mode: StopMode) {
		prompts.ask(.stop(PendingStop(vm: vm.name, mode: mode))) { shown, new in
			guard let a = shown.stop, let b = new.stop else { return false }
			return a.vm == b.vm && a.mode == b.mode
		}
	}

	public func confirmStop(_ pending: PendingStop) {
		if pendingStop?.id == pending.id { dismissCurrentPrompt() }
		stopVM(pending.vm, mode: pending.mode)
	}

	// MARK: - New VM

	// New VM… (⌘N) opens the same template chooser as the picker's own New VM… row.
	public func requestNewVM() {
		newVMChooserRequested = true
	}

	// MARK: - Dock menu

	// One Dock item per VM: Shut Down while it may be running (its state unknown too, C15),
	// Start otherwise. The list is the app-scoped store's, so it shows while reconnecting —
	// with every item disabled until a view model can act on it.
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
			let running = vm.mayBeRunning
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
		if vm.mayBeRunning {
			stopVM(name, mode: .soft)
		} else {
			startPolicyDriven(vm)
		}
	}
}
