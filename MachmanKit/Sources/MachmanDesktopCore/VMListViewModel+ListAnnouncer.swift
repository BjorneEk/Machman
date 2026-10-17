//
//  VMListViewModel+ListAnnouncer.swift
//  MachmanDesktopCore
//
//  What the desktop says unasked. Off the list's movement, fed by every refresh: a VM's
//  state outcome, the SSH story (the guest answering, its sshd, a setup run's result) and a
//  re-run discovery's answer (F4) — a first sighting never toasts, only a change does. Off
//  the event stream: the engine's warnings. Off the connection: the list-stale status toast
//  (P13), the actions a lost connection cut off (P12) and the settings files set aside at
//  launch (P19). The diff memory sits in the class body (VMListViewModel.swift).
//

import Foundation
import MachmanUI
import MachmanAPI
import MachmanClient

extension VMListViewModel {
	public static func sshWaitToastKey(_ vm: String) -> String { "ssh-wait-\(vm)" }
	public static func rediscoveryToastKey(_ vm: String) -> String { "rediscover-\(vm)" }
	public static func logToastKey(_ text: String) -> String { "log:" + text }

	// The list's movement, after every refresh (listRefreshed): outcomes first, then SSH.
	func announce(_ list: [VMInfo]) {
		diffStatesAndToast(list)
		diffSSHAndToast(list)
	}

	// Outcome toasts off the list itself (every patch and reload lands here): a VM newly
	// running/stopped/errored toasts exactly once, transitions stay quiet, and a first
	// sighting (launch, reconnect, creation) never toasts.
	private func diffStatesAndToast(_ list: [VMInfo]) {
		for vm in list {
			let previous = knownStates[vm.name]
			knownStates[vm.name] = vm.state
			guard let previous, previous != vm.state else { continue }
			// unknown = the daemon could not tell (a vmhost not adopted yet, or one that
			// never answered): whatever it turns out to be was already so.
			guard previous != .unknown else { continue }
			switch vm.state {
			case .running:
				pushToast(symbol: MachmanSymbols.start, message: "\(vm.name) started")
			case .stopped where previous == .running || previous == .stopping:
				pushToast(symbol: MachmanSymbols.shutDown, message: "\(vm.name) stopped")
			case .error:
				pushProblem(
					symbol: MachmanSymbols.warning, message: "\(vm.name) hit an error",
					tint: MachmanColors.warning, vm: vm.name, detail: "Stopped with an error",
					severity: .failure)
			default:
				break
			}
		}
		let names = Set(list.map(\.name))
		knownStates = knownStates.filter { names.contains($0.key) }
	}

	// What the SSH half of a VM looked like last time, so only MOVEMENT is reported.
	struct SSHSnapshot: Equatable {
		var running = false
		var address: String?
		var reachability: SSHInfo.Reachability?
		var lastReportAt: Date?
		var reverseState: SSHInfo.ReverseState = .none
		var setupReportAt: Date?
		var setupRun: SetupRun?
	}

	// What a setup RUN decided, as opposed to what any report re-probes (features, consoles,
	// automounts, OS facts): a boot-time refresh replays the last run's outcome unchanged,
	// so only a change here is a run worth a toast.
	struct SetupRun: Equatable {
		var installed: Bool?
		var status: String?
		var note: String?
		var errors: [GuestSetupError]?
		var notes: [GuestSetupNote]?
		var scriptVersion: Int?

		init?(_ setup: GuestSetupInfo?) {
			guard let setup else { return nil }
			installed = setup.installed
			status = setup.lastRunStatus
			note = setup.lastRunNote
			errors = setup.errors
			notes = setup.notes
			scriptVersion = setup.scriptVersion
		}
	}
	// The SSH story, told through toasts: the guest answering at all, then whether its
	// sshd does, then what its setup run achieved. Same rule as the state diff — a first
	// sighting (launch, reconnect) never toasts, only a change does.
	private func diffSSHAndToast(_ list: [VMInfo]) {
		for vm in list {
			let now = SSHSnapshot(
				running: vm.state.isRunning,
				address: vm.ssh?.address,
				reachability: vm.ssh?.reachability,
				lastReportAt: vm.ssh?.lastReportAt,
				reverseState: vm.ssh?.reverseState ?? .none,
				setupReportAt: vm.setup?.lastReportAt,
				setupRun: SetupRun(vm.setup))
			let previous = knownSSH[vm.name]
			knownSSH[vm.name] = now
			// A re-run discovery that heard back says what it found, unchanged or not.
			if rediscovering[vm.name] != nil, rediscoveryAnswered.contains(vm.name),
				let address = now.address {
				endRediscovery(vm.name)
				if previous?.address == address {
					pushToast(
						symbol: MachmanSymbols.network,
						message: "\(vm.name) is still at \(address)",
						key: Self.rediscoveryToastKey(vm.name))
				}   // else the "answered" toast below says it
			}
			guard let previous, previous != now else { continue }

			// The guest is on the network — the first sign of life Machman gets.
			if let address = now.address, previous.address != address, now.running {
				pushToast(
					symbol: MachmanSymbols.network, message: "\(vm.name) answered — \(address)")
			}
			if previous.reachability != now.reachability {
				switch now.reachability {
				case .waiting:
					pushToast(
						symbol: MachmanSymbols.deviceSSHSetup,
						message: "\(vm.name): SSH connecting…",
						key: Self.sshWaitToastKey(vm.name), spinner: true, sticky: true)
				case .ready:
					pushToast(
						symbol: MachmanSymbols.confirm, message: "\(vm.name): SSH ready",
						tint: MachmanColors.connected, key: Self.sshWaitToastKey(vm.name))
				case .unreachable:
					pushToast(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): SSH not answering"
							+ (vm.ssh?.reachabilityDetail.map { " — \($0)" } ?? ""),
						tint: MachmanColors.warning, key: Self.sshWaitToastKey(vm.name))
				case .unknown, nil:
					dismissToast(key: Self.sshWaitToastKey(vm.name))
				}
			}
			// A setup run landed. One toast per run: the unified (v3) report speaks for
			// the whole run; the SSH-only phrasing survives for v2 guests, whose reports
			// carry no setup half. Every boot re-sends the report: a refresh that changed
			// only what it probes, not the run's outcome, stays quiet.
			let setupLanded = now.setupReportAt != nil
				&& previous.setupReportAt != now.setupReportAt
				&& previous.setupRun != now.setupRun
			if setupLanded {
				if vm.setup?.installed == false {
					pushToast(
						symbol: MachmanSymbols.deviceGuestSetup,
						message: "\(vm.name): guest setup removed")
				} else if let status = vm.setup?.lastRunStatus, status != GuestRunStatus.ok {
					pushProblem(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): guest setup \(status) — details in the "
							+ "inspector",
						tint: MachmanColors.warning, vm: vm.name,
						detail: "Guest setup \(status) — details in the inspector",
						severity: .warning)
				} else {
					pushToast(
						symbol: MachmanSymbols.deviceGuestSetup,
						message: "\(vm.name): guest setup complete")
				}
			} else if vm.setup?.lastReportAt == nil, let stamp = now.lastReportAt,
				previous.lastReportAt != stamp {
				let user = vm.ssh?.guestUser ?? "the guest"
				// The OS by name, never its raw id (W6); one Machman doesn't know is left out.
				let os = GuestOSName.known(vm.ssh?.guestOS).map { " (\($0))" } ?? ""
				if let status = vm.ssh?.lastRunStatus, status != GuestRunStatus.ok {
					let note = vm.ssh?.lastRunNote.map { " — \($0)" } ?? ""
					pushProblem(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): SSH setup \(status)\(note)",
						tint: MachmanColors.warning, vm: vm.name,
						detail: "SSH setup \(status)\(note)", severity: .warning)
				} else {
					pushToast(
						symbol: MachmanSymbols.deviceSSHSetup,
						message: "\(vm.name): SSH set up for \(user)\(os)")
				}
			}
			if previous.reverseState != .pending, now.reverseState == .pending {
				pushProblem(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "\(vm.name) asks to log in to this Mac — approve it in the "
						+ "SSH section",
					tint: MachmanColors.warning, vm: vm.name,
					detail: "Asks to log in to this Mac — approve it in the SSH section",
					severity: .warning)
			}
		}
		// A VM that stopped or vanished has no pending SSH wait to report on.
		let names = Set(list.map(\.name))
		for name in knownSSH.keys where !names.contains(name) {
			knownSSH[name] = nil
			dismissToast(key: Self.sshWaitToastKey(name))
		}
		for vm in list where !vm.state.isRunning {
			dismissToast(key: Self.sshWaitToastKey(vm.name))
		}
		// …nor a re-run discovery to wait on.
		let running = Set(list.filter { $0.state.isRunning }.map(\.name))
		for name in rediscovering.keys where !running.contains(name) {
			endRediscovery(name)
		}
	}

	// The spinner goes up before the RPC: an answer can beat its reply.
	func beginRediscovery(_ name: String) {
		rediscovering[name]?.cancel()
		rediscoveryAnswered.remove(name)
		pushToast(
			symbol: MachmanSymbols.network, message: "Looking for \(name)’s address…",
			key: Self.rediscoveryToastKey(name), spinner: true, sticky: true)
		let wait = rediscoveryWait
		rediscovering[name] = Task { [weak self] in
			try? await Task.sleep(for: wait)
			guard !Task.isCancelled, let self else { return }
			self.rediscovering[name] = nil
			self.rediscoveryAnswered.remove(name)
			self.pushToast(
				symbol: MachmanSymbols.network,
				message: "No address for \(name) yet — Machman keeps looking",
				key: Self.rediscoveryToastKey(name))
		}
	}

	// The wait is over; its toast is replaced by whoever says how it ended.
	func endRediscovery(_ name: String) {
		rediscovering.removeValue(forKey: name)?.cancel()
		rediscoveryAnswered.remove(name)
		dismissToast(key: Self.rediscoveryToastKey(name))
	}

	// MARK: - Engine warnings

	// The engine logs these in its own process too, but that process is auto-launched —
	// relaying through the client's logger keeps engine warnings visible from the app
	// the user actually runs.
	func announceEngineLog(vm: String?, level: LogLevel, message: String) {
		// Not written to the log here: the process that emitted it did (E69).
		if level == .warning || level == .error {
			// Keyed by its text: a warning repeated while its toast shows restarts that
			// toast instead of stacking another copy (P15).
			let text = Self.engineLogText(vm: vm, message: message)
			pushToast(
				symbol: MachmanSymbols.warning, message: text, tint: MachmanColors.warning,
				key: Self.logToastKey(text))
			// The toast goes in seconds; the activity list keeps the whole text (F6).
			activity.record(.engineLog(
				vm: vm, level: level, message: message, at: MachmanClock.now()))
		}
	}

	// How an engine warning or error reads as a toast and an Activity entry's key: "<VM>: <the
	// engine's sentence>". The engine's boot-time warnings leave the VM out for that (W3), but
	// an older daemon's, and refusals relayed as error events, already start with it — those
	// stand as they are, so a toast names the VM once (wording rule 5).
	// "Debian has no display device — started headless" (a 1.0.12 daemon) stays as it is;
	// "It has no display, so it started headless." reads "Debian: It has no display, …". The
	// name must end on a word boundary: "Deb" does not start "Debian x".
	public static func engineLogText(vm: String?, message: String) -> String {
		guard let vm, !vm.isEmpty else { return message }
		if message.hasPrefix(vm) {
			let rest = message.dropFirst(vm.count)
			if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { return message }
		}
		return "\(vm): \(message)"
	}

	// MARK: - The connection

	// What the connection's state says: a status toast that lives exactly as long as the
	// state it reports, and — after a reconnect — what the lost connection cut off.
	public static let listProblemToastID = UUID()
	public static let listProblemMessage = "Couldn’t refresh the VM list — retrying"

	// The list on screen may be stale: shown until a refresh lands (P13).
	public var statusToasts: [MachmanToast] {
		guard store.listProblem != nil else { return [] }
		return [MachmanToast(
			id: Self.listProblemToastID, symbol: MachmanSymbols.warning,
			message: Self.listProblemMessage, tint: MachmanColors.warning,
			spinner: true, sticky: true)]
	}

	// After a reconnect: one alert naming the user's actions that were still in flight when
	// the connection dropped (P12). The old view model — and any alert it would have shown
	// for them — went with the connection; this one says it instead.
	public func announceInterrupted(_ calls: [InterruptedCall]) {
		guard let message = InterruptedActions.message(calls) else { return }
		present(title: Self.connectionLostTitle, message: message)
	}

	public static let connectionLostTitle = "The connection to Machman Agent was lost"

	// Settings files a store could not read at launch and set aside as a .bak (P19): one
	// toast each, the first time a view model asks (a reconnect's never repeats it).
	public func announceSetAsideSettings(_ stores: [any SetAsideReporting]) {
		for store in stores {
			guard let file = store.takeSetAsideNotice() else { continue }
			pushToast(
				symbol: MachmanSymbols.info,
				message: "Couldn’t read your \(file.what) — the old file is kept as "
					+ file.backup.lastPathComponent)
		}
	}
}
