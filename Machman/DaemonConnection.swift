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
import ServiceManagement
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
	// Approval is orthogonal to socket state (it can be pending while a manually-run daemon
	// serves), so it is a flag beside Status, not a fourth case.
	@Published private(set) var loginItemNeedsApproval = false
	private var api: RemoteMachman?
	private var connectTask: Task<Void, Never>?
	private var viewModelForwarder: AnyCancellable?
	private let loginItem = SMAppService.loginItem(identifier: DaemonConnection.daemonBundleID)

	// XCTestConfigurationFilePath is set for the whole TEST_HOST process, so this also covers
	// Swift Testing suites (they run inside the XCTest-launched host, not a separate runner).
	private var isRunningTests: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
	}

	init() {
		registerLoginItem()
		connect()
	}

	func retry() {
		registerLoginItem()   // re-check approval on every user-driven retry
		connectTask?.cancel()
		connectTask = nil
		connect()
	}

	func openLoginItemsSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}

	// Login-at-boot is an INSTALL feature: dev builds never touch Login Items, and even a
	// Release build refuses when running out of DerivedData. Dev keeps on-demand launch via
	// launchDaemon(). Nothing ever unregisters — quit-leave-VMs must not delist the daemon.
	private func registerLoginItem() {
		#if DEBUG
		return
		#else
		guard !Bundle.main.bundleURL.path.contains("/DerivedData/") else { return }
		guard !isRunningTests else { return }   // tests must not mutate Login Items
		switch loginItem.status {
		case .enabled:
			loginItemNeedsApproval = false
			return
		default:
			break
		}
		do {
			// NOTE: registering an approvable login item LAUNCHES it — fine, it's the daemon
			// we want running; the socket race arbitrates against a second copy.
			try loginItem.register()
		} catch {
			MachmanLogger.log(.passiveWarning, "login item registration failed: \(error)")
		}
		loginItemNeedsApproval = (loginItem.status == .requiresApproval)
		#endif
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

	// The embedded copy is guaranteed by the build — launch by explicit URL, gated by an id
	// check against a half-built bundle. Launch Services stays as the fallback for a desktop
	// whose embeds are missing or broken. (The old sibling hunt died with the one-bundle
	// layout: the embedded daemon always comes from the same products dir as the desktop,
	// sanitizer variants included.)
	func launchDaemon() {
		let embedded = Bundle.main.bundleURL
			.appendingPathComponent("Contents/Library/LoginItems/Machmand.app")
		if Bundle(url: embedded)?.bundleIdentifier == Self.daemonBundleID {
			NSWorkspace.shared.openApplication(
				at: embedded, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		if let url = NSWorkspace.shared.urlForApplication(
			withBundleIdentifier: Self.daemonBundleID) {
			NSWorkspace.shared.openApplication(
				at: url, configuration: NSWorkspace.OpenConfiguration())
			return
		}
		MachmanLogger.log(.passiveError,
			"no \(Self.daemonBundleID) embedded in this app or known to Launch Services")
	}
}
