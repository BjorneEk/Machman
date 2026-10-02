//
//  DaemonConnection.swift
//  MachmanDesktop
//
//  Owns the desktop app's link to MachmanAgent: the glue between the bounded connect loop
//  (ConnectionLoop, MachmanDesktopCore — attempts, agent launch, stop conditions, stale
//  sessions) and the app: launching the agent, attaching the app-scoped stores, and a fresh
//  view model per connection.
//

import Foundation
import AppKit
import Combine
import ServiceManagement
import MachmanAPI
import MachmanUI
import MachmanClient
import MachmanDesktopCore
import MachmanDesktopUI

@MainActor
final class DaemonConnection: ObservableObject {
	// Derived, never hardcoded: a Debug build must look for the .dev agent, not the production
	// one. Same suffix rule MachmanPaths uses to collapse helper ids back to the suite.
	static var daemonBundleID: String { MachmanPaths.suiteIdentifier() + ".agent" }

	@Published private(set) var status: ConnectionStatus = .connecting
	@Published private(set) var viewModel: VMListViewModel?
	// App-scoped stores that survive reconnects: each new connection re-attaches them, each
	// new view model is a facade over them. DaemonConnection is their composition root
	// because it is the one object that sees every (re)connection.
	let vmStore = VMStore()
	// Its activity list is saved, so finished work and warnings outlive a relaunch (PR5).
	let operationsStore = OperationsStore(activity: ActivityLog(fileURL: ActivityLog.defaultURL()))
	// Not api-bound (nothing to re-attach): open terminal tabs + their live SwiftTerm
	// controllers, kept out of the per-connection teardown so transcripts survive it.
	let terminals = TerminalSessions.swiftTerm()
	// Per-VM canvas layouts (panes/tabs/fractions), persisted to disk by the store itself.
	let canvases = CanvasStateStore()
	let previews: PreviewService
	// Approval is orthogonal to socket state (it can be pending while a manually-run daemon
	// serves), so it is a flag beside the status, not a fourth case.
	@Published private(set) var loginItemNeedsApproval = false
	private var api: RemoteMachman?
	private var loop: ConnectionLoop<RemoteMachman>!
	// App-scoped like the previews it pauses: one watcher for the app's lifetime, never one
	// per connection or per mounted pane (P3).
	private var focus: FocusMonitor?
	private var viewModelForwarder: AnyCancellable?
	private let loginItem = SMAppService.loginItem(identifier: DaemonConnection.daemonBundleID)

	// XCTestConfigurationFilePath is set for the whole TEST_HOST process, so this also covers
	// Swift Testing suites (they run inside the XCTest-launched host, not a separate runner).
	private var isRunningTests: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
	}

	// The agent may be launched but still starting, or hung: a hello bounded well under the
	// RPC default lets the loop say "not answering" after two tries instead of a minute.
	static let helloDeadline: Duration = .seconds(10)

	init() {
		// The registry the torn-off windows and the view model use: their Configuration tabs
		// get live frames too.
		previews = PreviewService(store: vmStore, tornTabs: .shared)
		focus = FocusMonitor.application { [previews] focused in
			previews.setFocused(focused)
		}
		loop = ConnectionLoop(
			connect: { onDrop in
				try await RemoteMachman(
					clientName: "MachmanDesktop", helloDeadline: Self.helloDeadline,
					onDisconnect: onDrop)
			},
			launchDaemon: { [weak self] in self?.launchDaemon() },
			attach: { [weak self] api, interrupted in self?.attach(api, interrupted) },
			detach: { [weak self] in self?.detached() },
			onStatus: { [weak self] status in self?.status = status })
		registerLoginItem()
		loop.start()
	}

	func retry() {
		registerLoginItem()   // re-check approval on every user-driven retry
		loop.retry()
	}

	// The connect screen's Launch Daemon: launch, then a fresh cycle that won't launch again.
	func launchAndRetry() {
		launchDaemon()
		registerLoginItem()
		loop.retry(launched: true)
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

	// A session the loop vetted: re-attach the app-scoped stores, then a fresh view model,
	// which first says what the last drop cut off (its alert shows once the window mounts).
	private func attach(_ api: RemoteMachman, _ interrupted: [InterruptedCall]) {
		vmStore.attach(api: api)
		operationsStore.attach(api: api)
		previews.attach(api: api)
		let viewModel = VMListViewModel(
			api: api, store: vmStore, operations: operationsStore,
			terminals: terminals, previews: previews, canvases: canvases)
		viewModel.announceInterrupted(interrupted)
		self.api = api
		self.viewModel = viewModel
		// The menu bar commands observe this object; forward list changes so Run/Stop/View
		// menus stay live.
		viewModelForwarder = viewModel.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		// Deferred a turn: its alert runs modal, never inside the loop's callback.
		let version = api.hello.daemonVersion
		Task { @MainActor [weak self] in
			self?.checkDaemonVersion(version)
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
	// 1.0.5: configs gained ssh — same drop-on-rewrite hazard, plus the vm.ssh.* methods.
	// 1.0.6: the ssh config grew again (alias, last address, run status, sshfs capability)
	// and payloads moved to <vmdir>/share — an older daemon drops the new keys on its next
	// rewrite and regenerates payloads in the old place.
	// 1.0.7: the two installer devices collapse into guestSetup (configs migrate on load —
	// an older daemon neither understands the migrated kind nor keeps the new setup and
	// mount-kind keys through its rewrite), and mounts gained kind.
	// 1.0.8: wire hygiene — vm.disk.remove refuses while the VM runs (an older daemon
	// still unlinks the live attachment's backing file), notifications are never answered
	// (JSON-RPC 2.0), and the closed wire enums decode unknown values tolerantly.
	// 1.0.9: vm.disk.promote refuses while the VM runs (an older daemon still copies the
	// image under the live attachment's writes and rewires the config beneath it, so the
	// next boot silently switches disks).
	// 1.0.10: the display device gained systemKeyCapture — an older daemon drops it on its
	// next rewrite, and its vmhosts would never apply it.
	// 1.0.11: Save as New VM moves the disks a safe run wrote directly into the saved VM
	// and rewrites the original to reference them — an older daemon never reloads the
	// original, so its stale copy can be saved over the rewrite — and the daemon gained the
	// safety refusals around it (shared disks, dropped vmhost connections, cross-volume
	// saves, a saved run on its source's socket).
	// 1.0.12: vm.setEnabled gained devices (an older daemon drops the key, so a batch toggle
	// silently skips devices), and the daemon refuses setting changes on VMs still run by an
	// older vmhost (E22) — whose floor is the daemon's own version.
	static let oldestCompatibleDaemonVersion = "1.0.12"

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

	// The attached session dropped; the loop reconnects (or stops) on its own.
	private func detached() {
		MachmanLogger.log(.passiveWarning, "daemon connection lost; reconnecting")
		vmStore.detach()
		operationsStore.detach()
		previews.detach()
		api = nil
		viewModel = nil
		viewModelForwarder = nil
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

// Torn-off tab windows follow the connection: its view model and terminal sessions.
extension DaemonConnection: TornTabConnection {}
