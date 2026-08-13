//
//  DaemonConnection.swift
//  MachmanDesktop
//
//  Owns the desktop app's link to MachmanAgent: connect, auto-launch the daemon when it isn't
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
	// App-scoped stores that survive reconnects: each new connection re-attaches them, each
	// new view model is a facade over them. DaemonConnection is their composition root
	// because it is the one object that sees every (re)connection.
	let vmStore = VMStore()
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
						clientName: "MachmanDesktop", onDisconnect: onDisconnect)
					guard let self = self else { return }
					self.vmStore.attach(api: api)
					let viewModel = VMListViewModel(api: api, store: self.vmStore)
					self.api = api
					self.viewModel = viewModel
					// The menu bar commands observe this object; forward list changes so
					// Run/Stop/View menus stay live.
					self.viewModelForwarder = viewModel.objectWillChange.sink { [weak self] in
						self?.objectWillChange.send()
					}
					self.status = .connected(daemonVersion: api.hello.daemonVersion)
					self.connectTask = nil
					self.checkDaemonVersion(api.hello.daemonVersion)
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

	// The compatibility floor: bump alongside MARKETING_VERSION whenever a change breaks the
	// old/new daemon mix (wire shapes, config format, behavior). Complements — does not
	// replace — the hard apiVersion gate.
	// 1.0.2: StartOptions.safe — an older daemon would silently ignore the flag and run the
	// real VM unsafely, so it must be replaced before this desktop issues any start.
	// 1.0.4: configs gained devices/enabled/kernelOverrides — an older daemon's rewrite
	// silently DROPS those keys (VMConfig encodes only enumerated keys), so it must be
	// replaced before it can save configs the new desktop depends on.
	static let oldestCompatibleDaemonVersion = "1.0.4"

	// The silent-skew detector: the desktop connects to whatever daemon serves, so IT is the
	// process that can tell "this daemon is older than what I ship". Below the floor → offer
	// a user-confirmed replacement (retire, then the reconnect path launches the embedded,
	// current-version daemon and re-adopts vmhosts).
	private func checkDaemonVersion(_ running: String) {
		guard MachmanVersion.isOlder(running, than: Self.oldestCompatibleDaemonVersion) else {
			let mine = Bundle.main
				.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
			if MachmanVersion.isOlder(mine, than: running) {
				// Reverse skew is tolerated by the additive-wire policy — log only.
				MachmanLogger.log(.log, "daemon \(running) is newer than this app (\(mine))")
			}
			return
		}
		let embedded = Bundle.main.bundleURL
			.appendingPathComponent("Contents/Library/LoginItems/MachmanAgent.app")
		guard Bundle(url: embedded)?.bundleIdentifier == Self.daemonBundleID else {
			// Nothing newer to launch — explain instead of offering a dead end.
			let alert = NSAlert()
			alert.messageText = "Machman Agent is too old"
			alert.informativeText = "The running daemon is version \(running); this app "
				+ "needs \(Self.oldestCompatibleDaemonVersion) or newer, and no newer "
				+ "Machman Agent is embedded in this app. Reinstall or rebuild."
			alert.runModal()
			return
		}
		let alert = NSAlert()
		alert.messageText = "The running Machman Agent is too old"
		alert.informativeText = "It is version \(running); this app needs "
			+ "\(Self.oldestCompatibleDaemonVersion) or newer. Start the new one? Running "
			+ "VMs keep running and are re-adopted."
		alert.addButton(withTitle: "Replace")
		alert.addButton(withTitle: "Not Now")
		guard alert.runModal() == .alertFirstButtonReturn else {
			MachmanLogger.log(.passiveWarning,
				"daemon \(running) is below the floor "
					+ "\(Self.oldestCompatibleDaemonVersion); newer features may fail")
			return
		}
		Task { [weak self] in
			// Retire drops the connection; the reconnect path launches the embedded daemon.
			try? await self?.api?.retire()
		}
	}

	private func disconnected() {
		MachmanLogger.log(.passiveWarning, "daemon connection lost; reconnecting")
		vmStore.detach()
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
			.appendingPathComponent("Contents/Library/LoginItems/MachmanAgent.app")
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
