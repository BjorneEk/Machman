//
//  DaemonConnection.swift
//  Machman
//
//  Owns the desktop app's link to Machmand: connect, auto-launch the daemon when it isn't
//  running, retry with backoff, and reconnect (with a fresh view model) if the daemon goes
//  away mid-session.
//

import Foundation
import AppKit
import Combine
import MachmanAPI
import MachmanClient

@MainActor
final class DaemonConnection: ObservableObject {
	enum Status: Equatable {
		case connecting
		case connected(daemonVersion: String)
		case unavailable(String)
	}

	// Derived, never hardcoded: a Debug build must look for the .dev agent, not the production
	// one. Same suffix rule MachmanPaths uses to collapse helper ids back to the suite.
	static var daemonBundleID: String { MachmanPaths.suiteIdentifier() + ".agent" }

	@Published private(set) var status: Status = .connecting
	@Published private(set) var viewModel: VMListViewModel?
	private var api: RemoteMachman?
	private var connectTask: Task<Void, Never>?
	private var viewModelForwarder: AnyCancellable?

	init() {
		connect()
	}

	func retry() {
		connectTask?.cancel()
		connectTask = nil
		connect()
	}

	private func connect() {
		guard connectTask == nil else { return }
		status = .connecting
		let onDisconnect: @Sendable () -> Void = { [weak self] in
			Task { @MainActor in
				self?.disconnected()
			}
		}
		connectTask = Task { [weak self] in
			var attempt = 0
			var launched = false
			var lastError = "unknown"
			while !Task.isCancelled, attempt < 20 {
				attempt += 1
				do {
					let api = try await RemoteMachman(
						clientName: "Machman-desktop", onDisconnect: onDisconnect)
					guard let self = self else { return }
					let viewModel = VMListViewModel(api: api)
					self.api = api
					self.viewModel = viewModel
					// The menu bar commands observe this object; forward list changes so
					// Run/Stop/View menus stay live.
					self.viewModelForwarder = viewModel.objectWillChange.sink { [weak self] in
						self?.objectWillChange.send()
					}
					self.status = .connected(daemonVersion: api.hello.daemonVersion)
					self.connectTask = nil
					return
				} catch {
					lastError = "\(error)"
					if !launched {
						launched = true
						self?.launchDaemon()
					}
					try? await Task.sleep(for: .milliseconds(500))
				}
			}
			guard let self = self, !Task.isCancelled else { return }
			self.status = .unavailable(lastError)
			self.connectTask = nil
		}
	}

	private func disconnected() {
		MachmanLogger.log(.passiveWarning, "daemon connection lost; reconnecting")
		api = nil
		viewModel = nil
		viewModelForwarder = nil
		connectTask?.cancel()
		connectTask = nil
		connect()
	}

	// Dev builds: the daemon sits next to this app in the build products dir (possibly across
	// a sanitizer-variant subdir). Otherwise ask Launch Services by bundle id.
	func launchDaemon() {
		var candidates: [URL] = []
		let ownDir = Bundle.main.bundleURL.deletingLastPathComponent()
		candidates.append(ownDir.appendingPathComponent("Machmand.app"))
		if ownDir.lastPathComponent.hasPrefix("Variant-") == false,
			ownDir.deletingLastPathComponent().lastPathComponent.hasPrefix("Variant-") {
			// .../Variant-X/Debug/Machman-desktop.app -> .../Debug/Machmand.app
			let base = ownDir.deletingLastPathComponent().deletingLastPathComponent()
			candidates.append(base
				.appendingPathComponent(ownDir.lastPathComponent)
				.appendingPathComponent("Machmand.app"))
		}
		// Only launch a sibling that belongs to OUR suite. A stale build product left over from
		// before the identifier changed will happily launch and then serve a different socket
		// (or refuse to start at all), which reads as an unexplained connection failure here.
		for candidate in candidates where siblingMatchesSuite(candidate) {
			NSWorkspace.shared.openApplication(
				at: candidate, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		if let url = NSWorkspace.shared.urlForApplication(
			withBundleIdentifier: Self.daemonBundleID) {
			NSWorkspace.shared.openApplication(
				at: url, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		MachmanLogger.log(.passiveError,
			"no \(Self.daemonBundleID) found next to this app or in Launch Services")
	}

	private func siblingMatchesSuite(_ url: URL) -> Bool {
		guard FileManager.default.fileExists(atPath: url.path) else { return false }
		guard let id = Bundle(url: url)?.bundleIdentifier else { return false }
		return id == Self.daemonBundleID
	}
}
