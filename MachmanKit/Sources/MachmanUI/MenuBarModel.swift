//
//  MenuBarModel.swift
//  MachmanUI
//
//  The menu-bar agent's model: its VM list, kept current from the engine's events, and the
//  actions its menu sends. Here rather than in the agent's app target so it tests headlessly
//  on a stub engine, as MenuBarRules does.
//

import SwiftUI
import AppKit
import MachmanAPI

// What a lab menu command did.
public enum LabMenuOutcome: Equatable, Sendable {
	case done
	case disabled
	case noSuchVM
}

@MainActor
public final class MenuBarModel: ObservableObject {
	let api: MachmanControlling
	@Published public private(set) var vms: [VMInfo] = []
	// Live macOS install phases by VM: an install's start emits no listChanged (P23).
	@Published private(set) var installPhases: [String: InstallPhase.Kind] = [:]
	private var eventTask: Task<Void, Never>?
	// Asks the user, a second time, whether to end a VM's process (C9). A seam: tests
	// answer it; the agent shows the alert in front, never modal inside a main-actor job.
	public var confirmEndProcess: @MainActor (EndProcessPrompt) async -> Bool = { prompt in
		await MainRunLoopCallout.run { prompt.runInFront() }
	}
	// Says that a menu action failed (P23); true when the user chose Start Anyway. A seam as
	// well: the agent's alert comes from a run-loop callout, never modal inside this
	// main-actor job, which would hold every other one (the daemon's request handling
	// included) until it is dismissed.
	public var presentFailure: @MainActor (MenuBarFailure) async -> Bool = { failure in
		await MainRunLoopCallout.run { MenuBarModel.present(failure) }
	}

	public init(api: MachmanControlling) {
		self.api = api
	}

	// Lists the VMs and follows the engine's events from now on; a second call does nothing.
	// Only an agent that serves the socket calls it (V9): a list adopts every live vmhost it
	// meets, so an agent that stepped aside for another (a same-version copy, or the
	// replace-older prompt answered with Cancel) took that agent's VMs over, and its own quit
	// prompt then offered to stop them.
	public func begin() {
		guard eventTask == nil else { return }
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

	// Start waits for a running macOS install, and for a VM that may be running (V11), as the
	// desktop's does.
	public func canStart(_ vm: VMInfo) -> Bool {
		vm.menuBarCanStart(phase: installPhases[vm.name])
	}

	// The desktop's start rule (StartIntent): the policy, overridden only where named.
	public func start(_ vm: VMInfo, _ intent: StartIntent) {
		let name = vm.name
		let options = vm.startOptions(intent)
		Task { await perform(.start(options), vm: name) }
	}

	// A Force Stop can't reach a VM whose vmhost doesn't answer: one listed as not
	// responding is asked about first, as the desktop does (C9).
	public func stop(_ name: String, mode: StopMode) {
		if mode == .force, vms.first(where: { $0.name == name })?.isUnresponsive == true {
			Task { await endProcessIfConfirmed(name) }
			return
		}
		Task { await perform(.stop(mode), vm: name) }
	}

	private func endProcessIfConfirmed(_ name: String) async {
		guard await confirmEndProcess(.forVM(name)) else { return }
		await perform(.endProcess, vm: name)
	}

	public func openWindow(_ name: String) {
		Task { await perform(.openWindow, vm: name) }
	}

	public func closeWindow(_ name: String) {
		Task { await perform(.closeWindow, vm: name) }
	}

	// Whether the menu's item for `action` is enabled for `vm`: the one rule the menu and the
	// lab's control socket share. A window item exists only while the VM runs with a display.
	public func isEnabled(_ action: LabMenuAction, _ vm: VMInfo) -> Bool {
		switch action {
		case .start, .startHeadless, .startSafe: return canStart(vm)
		case .shutDown, .forceStop: return vm.menuBarCanStop
		case .openWindow: return vm.windowAction == .open
		case .closeWindow: return vm.windowAction == .close
		}
	}

	// The lab's `menu <action> <vm>` (test mode only): the item, as if chosen from the menu,
	// only where the menu would enable it.
	public func performLab(_ action: LabMenuAction, vm name: String) -> LabMenuOutcome {
		guard let vm = vms.first(where: { $0.name == name }) else { return .noSuchVM }
		guard isEnabled(action, vm) else { return .disabled }
		switch action {
		case .start: start(vm, .plain)
		case .startHeadless: start(vm, .headless)
		case .startSafe: start(vm, .safe)
		case .shutDown: stop(name, mode: .soft)
		case .forceStop: stop(name, mode: .force)
		case .openWindow: openWindow(name)
		case .closeWindow: closeWindow(name)
		}
		return .done
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
			case .endProcess:
				do {
					try await api.endProcess(vm: name)
				} catch let error as MachmanError where error.code == .unsupported {
					// An engine from before vm.process.end: the force stop it knows (F12).
					try await api.stop(vm: name, mode: .force)
				}
			}
		} catch {
			let failure = MenuBarFailure(vm: name, action: action, error: error)
			if failure.isCanceled { return }
			if failure.offersEndProcess {
				// The stop ran out the daemon's bound: ask about the process instead.
				await endProcessIfConfirmed(name)
				return
			}
			// Logged first: the alert of an LSUIElement app can end up behind everything.
			MachmanLogger.log(.interactionError, "\(failure.title): \(failure.message)")
			let startAnyway = await presentFailure(failure)
			if startAnyway, let forced = failure.forceStart {
				await perform(.start(forced), vm: name)
			}
		}
	}

	// True when the user chose Start Anyway.
	private static func present(_ failure: MenuBarFailure) -> Bool {
		let answer = PromptAlert.run(failure.labPrompt)
		return failure.forceStart != nil && answer == 0
	}
}
