//
//  MacInstallController.swift
//  Machman
//
//  Observable wrapper around MacInstaller for the macOS boot tab: VMConfig has no @Published,
//  so this publishes the install phase + progress for SwiftUI, keeps config.boot as the
//  persisted mirror, and pokes the list view model on terminal transitions.
//

import Foundation

@MainActor
final class MacInstallController: ObservableObject {
	enum Phase: Equatable {
		case idle
		case resolving
		case downloading(version: String, build: String)
		case installing(version: String)
		case installed
		case failed(String)
		case interrupted
	}

	@Published private(set) var phase: Phase = .idle
	@Published private(set) var downloadProgress: Progress?
	@Published private(set) var installProgress: Progress?
	@Published private(set) var downloadStart: Date?

	private let vm: VirtualMachine
	private weak var listViewModel: VMListViewModel?
	private var installer: MacInstaller?
	private var version = "macOS"

	var isInstalling: Bool { installer != nil }
	var vmIsRunning: Bool { vm.config.state == .running }

	init(vm: VirtualMachine, listViewModel: VMListViewModel?) {
		self.vm = vm
		self.listViewModel = listViewModel
		reconcile()
	}

	// Maps persisted boot state to a UI phase. Pure so it's testable; a persisted .installing
	// with no live install means the app quit mid-install (interrupted).
	nonisolated static func phase(for boot: BootConfig, hasActiveInstall: Bool) -> Phase {
		switch boot {
		case .efi, .linuxKernel:
			return .idle
		case .macOS(let m):
			switch m.installState {
			case .installed:
				return .installed
			case .failed(let msg):
				return .failed(msg)
			case .installing:
				return hasActiveInstall ? .installing(version: "macOS") : .interrupted
			}
		}
	}

	func reconcile() {
		guard installer == nil else { return }   // a live install owns the phase
		phase = Self.phase(for: vm.config.boot, hasActiveInstall: false)
	}

	func installLocal(_ url: URL) {
		startInstall(source: .localIPSW(url))
	}

	func installLatest() {
		startInstall(source: .latestSupported)
	}

	func cancel() {
		installer?.cancel()
	}

	private func startInstall(source: MacInstaller.Source) {
		guard installer == nil else { return }
		guard vm.config.state != .running else {
			// Two live VZ VMs would contend for the same disk images.
			phase = .failed("Stop the VM before installing macOS")
			vm.log(error: "Refused macOS install for \(vm.config.name): the VM is running")
			return
		}
		let installer = MacInstaller(config: vm.config)
		self.installer = installer
		let isRemote: Bool
		if case .latestSupported = source { isRemote = true } else { isRemote = false }
		installer.onResolved = { [weak self] version, build in
			guard let self = self else { return }
			self.version = version
			self.phase = isRemote
				? .downloading(version: version, build: build)
				: .installing(version: version)
		}
		installer.onDownloadProgress = { [weak self] progress in
			self?.downloadProgress = progress
			self?.downloadStart = Date()
		}
		installer.onInstallProgress = { [weak self] progress in
			guard let self = self else { return }
			self.installProgress = progress
			self.phase = .installing(version: self.version)
		}
		phase = .resolving
		vm.log(message: "Starting macOS install for \(vm.config.name)")
		listViewModel?.forceUpdate()   // e.g. the Run button disables while installing
		Task {
			do {
				try await installer.install(source: source)
				self.phase = .installed
				self.vm.log(message: "macOS install finished for \(self.vm.config.name)")
			} catch {
				if case .macOS(let m) = self.vm.config.boot,
					case .failed(let msg) = m.installState {
					self.phase = .failed(msg)        // the installer recorded the reason
				} else if (error as? URLError)?.code == .cancelled {
					// download cancelled before any state change: clean never-mind
					self.phase = Self.phase(for: self.vm.config.boot, hasActiveInstall: false)
				} else {
					self.phase = .failed(error.localizedDescription)
				}
				// Log the full error: NSError domain/code (e.g. VZErrorDomain 10006) matter.
				self.vm.log(error: "macOS install failed: \(error)")
			}
			self.installer = nil
			self.downloadProgress = nil
			self.installProgress = nil
			self.downloadStart = nil
			self.listViewModel?.forceUpdate()
		}
	}
}
