//
//  InstallSession.swift
//  Machman
//
//  Engine-side macOS install session for one VM: drives MacInstaller, holds the current
//  InstallPhase snapshot, and broadcasts every change as an event. UI-free — clients render
//  phases from the event stream (and can query the current one at any time).
//

import Foundation
import MachmanAPI

@MainActor
final class InstallSession {
	// What drives one install. Production runs the real MacInstaller; tests inject a runner
	// that never reaches Virtualization (an install starts by loading a restore image).
	typealias Runner = @MainActor (MacInstaller, MacInstaller.Source) async throws -> Void
	static let runInstaller: Runner = { try await $0.install(source: $1) }

	let config: VMConfig
	private let events: EventBus
	private let isVMRunning: () -> Bool
	private let run: Runner
	private var installer: MacInstaller?
	private var version = "macOS"

	private var downloadProgress: Progress?
	private var installProgress: Progress?
	private var downloadStart: Date?
	private var progressTimer: Timer?

	private(set) var phase: InstallPhase {
		didSet {
			guard phase != oldValue else { return }
			events.emit(.installPhaseChanged(vm: config.name, phase: phase))
		}
	}

	var isInstalling: Bool { installer != nil }

	// The error event a failed install sends (a toast and an Activity entry), H31.
	nonisolated static func failureEvent(for error: Error) -> String {
		"The macOS install failed: \(MachmanError.userMessage(for: error))"
	}

	// `run` nil = the real installer. Resolved in the body: a default argument is evaluated
	// outside the main actor, where runInstaller is out of reach.
	init(
		config: VMConfig, events: EventBus, isVMRunning: @escaping () -> Bool,
		run: Runner? = nil
	) {
		self.config = config
		self.events = events
		self.isVMRunning = isVMRunning
		self.run = run ?? Self.runInstaller
		self.phase = Self.phase(for: config.boot, hasActiveInstall: false)
	}

	// Maps persisted boot state to a phase. Pure so it's testable; a persisted .installing
	// with no live install means the app quit mid-install (interrupted).
	nonisolated static func phase(for boot: BootConfig, hasActiveInstall: Bool) -> InstallPhase {
		switch boot {
		case .efi, .linuxKernel, .unknown:
			return InstallPhase(kind: .idle)
		case .macOS(let m):
			switch m.installState {
			case .installed:
				return InstallPhase(kind: .installed)
			case .failed(let msg):
				return InstallPhase(kind: .failed, message: msg)
			case .installing:
				return hasActiveInstall
					? InstallPhase(kind: .installing, version: "macOS")
					: InstallPhase(kind: .interrupted)
			}
		}
	}

	func startInstall(source: InstallSource) throws {
		// A second start used to answer success while the first install kept running (E15b).
		guard installer == nil else {
			throw MachmanError(
				code: .invalidState, message: "macOS is already installing on \(config.name)")
		}
		// Refused here, before any phase changes; MacInstaller guards its other callers (C11).
		if case .unknown = config.boot {
			throw BootConfig.newerModeRefusal
		}
		guard !isVMRunning() else {
			// Two live VZ VMs would contend for the same disk images.
			phase = InstallPhase(kind: .failed, message: "Stop the VM before installing macOS")
			throw VirtualMachineError.critical("Stop \(config.name) before installing macOS")
		}
		let installerSource: MacInstaller.Source
		switch source.kind {
		case .latest:
			installerSource = .latestSupported
		case .ipsw:
			guard let path = source.path, !path.isEmpty else {
				throw VirtualMachineError.critical("An IPSW install needs a file path")
			}
			installerSource = .localIPSW(URL(fileURLWithPath: path))
		}
		let installer = MacInstaller(config: config)
		self.installer = installer
		let isRemote = source.kind == .latest
		installer.onResolved = { [weak self] version, build in
			guard let self = self else { return }
			self.version = version
			self.phase = isRemote
				? InstallPhase(kind: .downloading, version: version, build: build)
				: InstallPhase(kind: .installing, version: version)
		}
		installer.onDownloadProgress = { [weak self] progress in
			self?.downloadProgress = progress
			self?.downloadStart = Date()
		}
		installer.onInstallProgress = { [weak self] progress in
			guard let self = self else { return }
			self.installProgress = progress
			self.phase = InstallPhase(
				kind: .installing, version: self.version,
				progress: Self.snapshot(progress))
		}
		phase = InstallPhase(kind: .resolving)
		startProgressTimer()
		events.emit(.log(
			vm: config.name, level: .message,
			message: "Starting macOS install for \(config.name)"))
		Task {
			do {
				try await self.run(installer, installerSource)
				self.phase = InstallPhase(kind: .installed)
				self.events.emit(.log(
					vm: self.config.name, level: .message,
					message: "macOS install finished for \(self.config.name)"))
			} catch {
				// A user cancel is a clean never-mind, not a failure — no error log/toast.
				// The installer's own flag counts too: whatever ends an install the user
				// canceled is that cancel (F10).
				let cancelled = installer.cancelled || MacInstaller.isCancellation(error)
				if case .macOS(let m) = self.config.boot,
					case .failed(let msg) = m.installState {
					self.phase = InstallPhase(kind: .failed, message: msg)
				} else if cancelled {
					self.phase = Self.phase(for: self.config.boot, hasActiveInstall: false)
				} else {
					self.phase = InstallPhase(
						kind: .failed, message: MachmanError.userMessage(for: error))
				}
				if cancelled {
					self.events.emit(.log(
						vm: self.config.name, level: .message,
						message: "macOS install cancelled"))
				} else {
					// Log the full error: NSError domain/code (VZErrorDomain 10006) matter.
					// The event says it in words.
					MachmanLogger.log(
						.passiveError, "macOS install of \(self.config.name) failed: \(error)")
					self.events.emit(.log(
						vm: self.config.name, level: .error,
						message: Self.failureEvent(for: error)))
				}
			}
			self.finishSession()
		}
	}

	func cancel() {
		installer?.cancel()
	}

	private func finishSession() {
		installer = nil
		downloadProgress = nil
		installProgress = nil
		downloadStart = nil
		stopProgressTimer()
	}

	// Foundation Progress doesn't cross the API; poll it into snapshots while a download or
	// install is live so subscribers see fraction/byte updates at a steady cadence.
	private func startProgressTimer() {
		progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.publishProgress()
			}
		}
	}

	private func stopProgressTimer() {
		progressTimer?.invalidate()
		progressTimer = nil
	}

	private func publishProgress() {
		guard installer != nil else { return }
		if phase.kind == .downloading, let progress = downloadProgress {
			phase = InstallPhase(
				kind: .downloading, version: version, build: phase.build,
				progress: Self.snapshot(progress), downloadStartedAt: downloadStart)
		} else if phase.kind == .installing, let progress = installProgress {
			phase = InstallPhase(
				kind: .installing, version: version,
				progress: Self.snapshot(progress))
		}
	}

	nonisolated private static func snapshot(_ progress: Progress) -> ProgressInfo {
		ProgressInfo(
			fraction: progress.fractionCompleted,
			completedBytes: progress.completedUnitCount,
			totalBytes: progress.totalUnitCount)
	}
}
