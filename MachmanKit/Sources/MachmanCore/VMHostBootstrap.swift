//
//  VMHostBootstrap.swift
//  MachmanCore
//
//  The whole vmhost program: a daemon that owns exactly one VM. Reuses the engine wholesale —
//  single-VM registry, LocalMachman, MachmanServer on the per-VM socket — plus a manual
//  NSApplication (the target is an LSUIElement app with no SwiftUI scene). The process exits
//  when its VM stops; MachmanAgent spawns a fresh one per start.
//

import Foundation
import AppKit
import MachmanAPI
import MachmanClient

public enum VMHostBootstrap {
	// Save as New VM renames the VM: its vmhost then answers on the saved VM's name-derived
	// socket, where daemons and launch agents look for a VM's host (E27) — on the original's,
	// a daemon restart adopted the run as the original. Only a host launched on such a path
	// moves (every daemon spawn and launch agent uses one); a failed move keeps the run on
	// the original's socket, and adoption still finds it by asking whom it serves.
	@MainActor
	static func followPromotions(
		of registry: VMRegistry, server: MachmanServer, launchedOn socketPath: String
	) {
		let dir = (socketPath as NSString).deletingLastPathComponent
		registry.onPromoted = { [weak server] from, to in
			guard let server,
				socketPath == MachmanPaths.vmSocketPath(vm: from, runtimeDir: dir) else { return }
			do {
				try server.relocate(to: MachmanPaths.vmSocketPath(vm: to, runtimeDir: dir))
			} catch {
				MachmanLogger.log(.passiveError,
					"\(to) still answers on \(from)'s socket: \(error)")
			}
		}
	}

	// Never returns: hands the thread to NSApplication.run().
	@MainActor
	public static func run(
		dataDir: String, vmName: String, socketPath: String, daemonVersion: String,
		autostart: Bool = false, library: String? = nil
	) -> Never {
		machmanVMDir = dataDir
		let lab = LabEnvironment.current

		// The first NSApp access, so the shared application IS the subclass: its sendEvent
		// is the only place the reserved chords can beat VZ's own key monitor.
		let app = VMHostApplication.shared
		app.setActivationPolicy(activationPolicy(lab: lab))

		// library is passed only for safe runs (dataDir = the shadow run root then); it is
		// the promotion destination for vm.safeSave, whose absence makes safeSave refuse.
		let registry = VMRegistry(only: vmName, promotionLibrary: library)
		// The VM window flips this process to a real app (Dock icon, menus) while a window is
		// open — a per-VM app the user can ⌘-Tab to — and back to accessory when it closes.
		registry.presenter.managesActivationPolicy = true
		// …and the window's system key capture, whose hotkeys, menus and full-screen chrome
		// are all process-wide — per VM only because this process is.
		registry.presenter.managesKeyCapture = true
		(app as? VMHostApplication)?.keyInterceptor = { [weak presenter = registry.presenter] in
			presenter?.interceptKey($0) ?? false
		}
		guard let vm = registry.vm(named: vmName) else {
			MachmanLogger.log(.passiveError, "no VM named '\(vmName)' in \(dataDir)")
			exit(64)
		}
		// launchd (RunAtLoad) launched us to boot our own VM. Policy is read from the CONFIG
		// here, not baked into the plist, so plists never rot on toggle edits.
		let policy = vm.config.startPolicy
		if autostart {
			admitLoginBoot(
				vm: vmName, policy: policy, library: dataDir,
				runtimeDir: (socketPath as NSString).deletingLastPathComponent)
		}
		let api = LocalMachman(registry: registry)
		let server = MachmanServer(
			api: api, socketPath: socketPath, daemonVersion: "\(daemonVersion)-vmhost")
		server.helloHost = helloHost(
			registry: registry, vmName: vmName, folder: VMFolderPath(vm.config.vmDirPath()),
			isShadow: library != nil)
		do {
			try server.start()
		} catch {
			MachmanLogger.log(.passiveError, "cannot serve \(socketPath): \(error)")
			exit(65)
		}
		followPromotions(of: registry, server: server, launchedOn: socketPath)

		// The delegate follows the registry's CURRENT name — safeSave promotion renames the
		// VM mid-run, and quit/stop must act on the live name, not the launch capture.
		let delegate = VMHostAppDelegate(
			vmName: { [weak registry] in registry?.restrictedName ?? vmName },
			presenter: registry.presenter, server: server,
			operations: {
				api.operationCenter.list().filter { $0.state == OperationInfo.State.running }
			})
		Self.appDelegate = delegate   // app.delegate is unowned — something must own it
		app.delegate = delegate
		serveLabControl(vm: vmName, lab: lab, delegate: delegate)
		app.mainMenu = buildMainMenu(
			vmName: vmName, delegate: delegate, presenter: registry.presenter)

		let lifecycle = VMHostLifecycle()
		// The run in flight, if any: VMRegistry.start sets it before its first await and
		// teardown clears it, so on this main actor it is a race-free "a start is under way".
		let currentRun = { registry.vm(named: registry.restrictedName ?? vmName)?.runtime }
		// Exit when the VM stops (after having run). Matches the registry's CURRENT name, not
		// the launch capture: safeSave promotion renames the VM mid-run and the stop that
		// ends the run arrives under the NEW name.
		Task { @MainActor in
			let stream = registry.events.stream()
			for await event in stream {
				guard case .stateChanged(let vm, let state) = event,
					vm == registry.restrictedName else {
					continue
				}
				if state.isRunning {
					lifecycle.hadRunning = true
				}
				if state == .stopped, lifecycle.hadRunning {
					// The stopped run may still be tearing down (its stopped state can arrive
					// first); only a DIFFERENT run counts — a start the daemon forwarded inside
					// the flush window (E12), which this host must keep serving.
					weak var stoppedRun = currentRun()
					try? await Task.sleep(for: .milliseconds(300))   // let replies/events flush
					// An import or kernel promote into the VM may still run here (E34).
					if !(await lifecycle.drain(operationsRunning: {
						api.operationCenter.hasRunning
					})) {
						MachmanLogger.log(.passiveWarning,
							"\(vm)'s vmhost exits under an operation past its deadline")
					}
					let run = currentRun()
					guard lifecycle.stopExitDue(running: run != nil && run !== stoppedRun) else {
						continue
					}
					exitHost(0, server: server)
				}
			}
		}
		// The idle backstop covers a spawn whose start never happened — the daemon died between
		// spawn and forward (the next daemon can still hand this host a start). It loops: a
		// start forwarded at the deadline is never killed, and one that failed still exits a
		// period later.
		Task { @MainActor in
			while true {
				try? await Task.sleep(for: .seconds(180))
				if lifecycle.hadRunning { return }   // the stop watcher owns the exit now
				if lifecycle.idleExitDue(
					startInFlight: currentRun() != nil,
					operationsRunning: api.operationCenter.hasRunning) {
					exitHost(0, server: server)
				}
			}
		}

		if autostart {
			// The login boot, admitted above. Woven after the watcher tasks above so no state
			// change goes unseen.
			Task { @MainActor in
				do {
					try await api.start(
						vm: vmName, options: StartOptions(openWindow: policy.windowed))
					// A sharer waiting for these locks refuses now (review F2).
					loginLocks?.markBooted()
					// Belt: never idle-exit a VM we just started (the watcher order above
					// is the suspenders).
					lifecycle.hadRunning = true
				} catch {
					// Exit now rather than sitting out the idle backstop with a dead start.
					MachmanLogger.log(.passiveError, "autostart of \(vmName) failed: \(error)")
					exitHost(70, server: server)
				}
			}
		}

		app.run()
		exitHost(0, server: server)
	}

	// Whom this vmhost serves, for hello (PR21): the agent adopts a vmhost as a VM only when it
	// serves that VM's folder (E11). The VM's current name and the data folder follow a Save
	// as New VM (the shadow is then the saved VM, in the library); the folder follows a rename
	// in Finder too.
	@MainActor
	static func helloHost(
		registry: VMRegistry, vmName: String, folder: VMFolderPath, isShadow: Bool
	) -> () -> RPCResults.Hello.Host? {
		{ [weak registry] in
			let current = registry?.restrictedName ?? vmName
			return RPCResults.Hello.Host(
				pid: getpid(), vm: current, dataDir: machmanVMDir, vmDir: folder.current,
				shadow: isShadow && current == vmName)
		}
	}

	@MainActor
	private static var appDelegate: VMHostAppDelegate?
	// A login boot's locks (E54), held for the run: they go with the process.
	@MainActor
	private static var loginLocks: BootGuard.LoginLocks?

	// A login boot is decided before this host binds its socket, so a sharer that will refuse
	// never shows a live one to a sharer that would boot (E54). This host sees one VM, so the
	// router's guards never ran (E38, C8): the login locks decide among login boots — a lock
	// a sharer holds is waited for while that sharer decides (review F2) — and a sharer the
	// agent started answers on its socket. Refused, it exits with the reason.
	@MainActor
	private static func admitLoginBoot(
		vm: String, policy: StartPolicy, library: String, runtimeDir: String
	) {
		guard !policy.safe else {
			// A stale plist racing a config edit — never run a safe-mode VM unsafely.
			MachmanLogger.log(.passiveError,
				"autostart of \(vm) refused: safe runs cannot autostart")
			exit(70)
		}
		switch BootGuard.claimLoginBoot(
			vm: vm, library: library, runtimeDir: runtimeDir,
			isLive: { UDSListener.isLive(path: $0) }) {
		case .success(let locks):
			loginLocks = locks
		case .failure(let refusal):
			MachmanLogger.log(.passiveError, "autostart of \(vm) refused: \(refusal.message)")
			exit(70)
		}
	}
	// Test mode only: the lab's control socket for this vmhost (Q23).
	@MainActor
	private static var labControl: LabControlServer?

	// Every exit stops what this process serves, the lab's control socket included.
	@MainActor
	private static func exitHost(_ code: Int32, server: MachmanServer) -> Never {
		stopServing(server)
		exit(code)
	}

	// What this process serves: its VM's socket and, under a test suite, the lab's control —
	// stopped by every exit, a quit that goes through at once too (review F3).
	@MainActor
	static func stopServing(_ server: MachmanServer) {
		labControl?.stop()
		labControl = nil
		server.stop()
	}

	// Under a test suite a vmhost can never become active or show a Dock icon (Q23); everywhere
	// else it is an accessory until its VM window opens.
	nonisolated static func activationPolicy(
		lab: LabEnvironment?
	) -> NSApplication.ActivationPolicy {
		lab == nil ? .accessory : .prohibited
	}

	// Test mode only: where this vmhost serves the lab's control — beside its agent's.
	nonisolated static func labControlPath(vm: String, lab: LabEnvironment?) -> String? {
		lab?.agentControlPath.map { LabControlPath.vmhost(agentControl: $0, vm: vm) }
	}

	// Test mode only: a lab test quits this vmhost for a chosen reason — the log out, restart
	// and shut down rows — without an Apple Event, which could raise an Automation prompt.
	// The quit comes after its reply is written.
	@MainActor
	private static func serveLabControl(
		vm: String, lab: LabEnvironment?, delegate: VMHostAppDelegate
	) {
		guard let path = labControlPath(vm: vm, lab: lab) else { return }
		do {
			labControl = try LabControlServer(path: path, handler: { command in
				switch command {
				case .ping:
					return "ok"
				case .quit(let reason):
					delegate.labQuitReason = VMHostQuitReason(lab: reason)
					return "ok"
				case .menu:
					return "error a vmhost has no menu"
				}
			}, afterReply: { command in
				guard case .quit = command else { return }
				MainRunLoopCallout.post { NSApp.terminate(nil) }
			})
		} catch {
			MachmanLogger.log(.log, "test mode: no lab control (\(error))")
		}
	}

	// Icon-less on purpose, and no Edit/Window menus — the keyboard belongs to the guest.
	// The bundle's display name is "Machman VM" (Dock, ⌘-Tab, Screen Recording). The bold
	// app-menu title may still read CFBundleName — MachmanVMHost, from PRODUCT_NAME, which
	// stays because VMHostLocator and the launch agents depend on it; the items and the window
	// title carry the VM name regardless.
	@MainActor
	private static func buildMainMenu(
		vmName: String, delegate: VMHostAppDelegate, presenter: WindowPresenter
	) -> NSMenu {
		let main = NSMenu()

		let appItem = NSMenuItem()
		main.addItem(appItem)
		let appMenu = NSMenu(title: vmName)
		appItem.submenu = appMenu
		appMenu.addItem(NSMenuItem(
			title: "Quit \(vmName)",
			action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

		let viewItem = NSMenuItem()
		main.addItem(viewItem)
		let viewMenu = NSMenu(title: "View")
		viewItem.submenu = viewMenu
		// nil target: the responder chain routes to the key window, so the existing
		// windowShouldClose prompt fires (window.close() would bypass it).
		viewMenu.addItem(NSMenuItem(
			title: "Close Window",
			action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
		viewMenu.addItem(.separator())
		viewMenu.addItem(KeyCaptureMenu.fullScreenItem())

		main.addItem(KeyCaptureMenu.keyboardMenuItem(target: presenter))

		let stopItem = NSMenuItem()
		main.addItem(stopItem)
		let stopMenu = NSMenu(title: "Stop")
		stopItem.submenu = stopMenu
		let shutDown = NSMenuItem(
			title: "Shut Down", action: #selector(VMHostAppDelegate.shutDown(_:)),
			keyEquivalent: "")
		shutDown.target = delegate
		stopMenu.addItem(shutDown)
		let forceStop = NSMenuItem(
			title: "Force Stop", action: #selector(VMHostAppDelegate.forceStop(_:)),
			keyEquivalent: "")
		forceStop.target = delegate
		stopMenu.addItem(forceStop)

		return main
	}
}

// When a vmhost exits on its own: after its VM's run stopped, or idle when no start ever came.
// Pure decisions over what the host saw, so the rules are testable without a VM.
@MainActor
final class VMHostLifecycle {
	var hadRunning = false

	// The idle backstop's verdict: never once a run happened, never while a start is in flight
	// or an operation runs — an import proxied to this idle host would die with it (E34).
	func idleExitDue(startInFlight: Bool, operationsRunning: Bool = false) -> Bool {
		!hadRunning && !startInFlight && !operationsRunning
	}

	// After a stop's flush: waits while the vmhost still runs an operation (an import into
	// the VM that just stopped), so the exit doesn't kill it and leave its staged copy behind
	// (E34). Bounded by the slow-class deadline its caller already gave up at. True once
	// nothing runs.
	func drain(
		operationsRunning: () -> Bool, limit: Duration = RPCConnection.slowCallDeadline,
		poll: Duration = .seconds(1),
		sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
	) async -> Bool {
		var waited = Duration.zero
		while operationsRunning() {
			guard waited < limit else { return false }
			await sleep(poll)
			waited += poll
		}
		return true
	}

	// After a stop's flush: exit unless a new run began meanwhile.
	func stopExitDue(running: Bool) -> Bool {
		hadRunning && !running
	}
}

// Quit semantics for a process that IS its VM: quitting while running has no "leave it
// running" option (that would be a lie — the VM dies with the host), so the prompt offers
// the two stop modes and Cancel, always answers .terminateCancel, and lets the existing
// stopped→exit(0) watcher stay the single teardown path. A log out, restart or shut down
// of the Mac is cancelled the same way (decision 6: never stop a guest on its own
// initiative), but visibly: the prompt comes to the front and says what to do. So is one
// that meets an import still finishing after the VM stopped (E46): the stop's exit waits
// for it (E34), bounded, and so does the session.
@MainActor
final class VMHostAppDelegate: NSObject, NSApplicationDelegate {
	// A provider, not a value: safeSave promotion renames the VM mid-run, and every action
	// here must target the live name. Only the (rebuilt-never) menu TITLES stay stale.
	private let vmName: () -> String
	private let presenter: WindowPresenter
	private let server: MachmanServer
	// The operations this vmhost still runs (an import into its VM), first started first.
	private let operations: () -> [OperationInfo]
	// Test mode only: the reason a lab `quit` asked for, read once in place of the quit
	// event's (Q23).
	var labQuitReason: VMHostQuitReason?

	init(
		vmName: @escaping () -> String, presenter: WindowPresenter, server: MachmanServer,
		operations: @escaping () -> [OperationInfo]
	) {
		self.vmName = vmName
		self.presenter = presenter
		self.server = server
		self.operations = operations
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false   // closing the window leaves the VM running; the host stays
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		terminateReply(for: takeQuitReason())
	}

	// A lab quit's reason stands in for the quit event's (`event`, for tests), once.
	func takeQuitReason(event: (() -> VMHostQuitReason)? = nil) -> VMHostQuitReason {
		defer { labQuitReason = nil }
		return labQuitReason ?? event?() ?? .current()
	}

	// The quit decision, apart from AppKit's call so tests can answer the prompt.
	func terminateReply(for reason: VMHostQuitReason) -> NSApplication.TerminateReply {
		let name = vmName()
		guard presenter.isRunning?(name) ?? false else {
			return replyWhileStopped(name, reason: reason)
		}
		switch presenter.present(.quitWhileRunning(name, reason: reason)) {
		case .shutDown:
			Task { await presenter.requestShutDown(name) }
		case .forceStop:
			Task { await presenter.requestForceStop(name) }
		case .closeWindow, .keepWaiting, .quitAnyway, .cancel:
			break
		}
		return .terminateCancel
	}

	// With the VM stopped, only an operation still running holds a quit (E46). The user's own
	// quit asks (C24); a log out, restart or shut down is canceled, and its alert comes after
	// this reply, as the agent's does (V10): the session waits on the reply, never on the
	// alert.
	private func replyWhileStopped(
		_ name: String, reason: VMHostQuitReason
	) -> NSApplication.TerminateReply {
		guard let work = operations().first else {
			VMHostBootstrap.stopServing(server)
			return .terminateNow
		}
		let activity = HostPrompt.activity(of: work)
		guard reason != .userQuit else {
			guard presenter.present(.quitDuringWork(name, activity: activity)) == .quitAnyway
			else { return .terminateCancel }
			VMHostBootstrap.stopServing(server)
			return .terminateNow
		}
		MachmanLogger.log(.log, "\(reason) canceled: \(name) \(activity)")
		Task { [presenter] in
			_ = await presenter.ask(.sessionEndDuringWork(name, activity: activity, reason: reason))
		}
		return .terminateCancel
	}

	// The Stop menu: the same requests, follow-up and refusal alerts as the close prompt.
	@objc func shutDown(_ sender: Any?) {
		let name = vmName()
		Task { await presenter.requestShutDown(name) }
	}

	@objc func forceStop(_ sender: Any?) {
		let name = vmName()
		Task { await presenter.requestForceStop(name) }
	}
}
