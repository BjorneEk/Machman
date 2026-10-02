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

		// The first NSApp access, so the shared application IS the subclass: its sendEvent
		// is the only place the reserved chords can beat VZ's own key monitor.
		let app = VMHostApplication.shared
		app.setActivationPolicy(.accessory)

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
		guard registry.vm(named: vmName) != nil else {
			MachmanLogger.log(.passiveError, "no VM named '\(vmName)' in \(dataDir)")
			exit(64)
		}
		let api = LocalMachman(registry: registry)
		let server = MachmanServer(
			api: api, socketPath: socketPath, daemonVersion: "\(daemonVersion)-vmhost")
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
			presenter: registry.presenter, server: server)
		Self.appDelegate = delegate   // app.delegate is unowned — something must own it
		app.delegate = delegate
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
					let run = currentRun()
					guard lifecycle.stopExitDue(running: run != nil && run !== stoppedRun) else {
						continue
					}
					server.stop()
					exit(0)
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
				if lifecycle.idleExitDue(startInFlight: currentRun() != nil) {
					server.stop()
					exit(0)
				}
			}
		}

		if autostart {
			// launchd (RunAtLoad) launched us; boot our own VM. Policy is read from the
			// CONFIG here, not baked into the plist, so plists never rot on toggle edits.
			// Woven after the watcher tasks above so no state change goes unseen.
			Task { @MainActor in
				let policy = registry.vm(named: vmName)?.config.startPolicy ?? StartPolicy()
				guard !policy.safe else {
					// A stale plist racing a config edit — never run a safe-mode VM unsafely.
					MachmanLogger.log(.passiveError,
						"autostart of \(vmName) refused: safe runs cannot autostart")
					server.stop()
					exit(70)
				}
				do {
					try await api.start(
						vm: vmName, options: StartOptions(openWindow: policy.windowed))
					// Belt: never idle-exit a VM we just started (the watcher order above
					// is the suspenders).
					lifecycle.hadRunning = true
				} catch {
					// Exit now rather than sitting out the idle backstop with a dead start.
					MachmanLogger.log(.passiveError, "autostart of \(vmName) failed: \(error)")
					server.stop()
					exit(70)
				}
			}
		}

		app.run()
		exit(0)
	}

	@MainActor
	private static var appDelegate: VMHostAppDelegate?

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

	// The idle backstop's verdict: never once a run happened, never while a start is in flight.
	func idleExitDue(startInFlight: Bool) -> Bool {
		!hadRunning && !startInFlight
	}

	// After a stop's flush: exit unless a new run began meanwhile.
	func stopExitDue(running: Bool) -> Bool {
		hadRunning && !running
	}
}

// Quit semantics for a process that IS its VM: quitting while running has no "leave it
// running" option (that would be a lie — the VM dies with the host), so the prompt offers
// the two stop modes and Cancel, always answers .terminateCancel, and lets the existing
// stopped→exit(0) watcher stay the single teardown path.
@MainActor
final class VMHostAppDelegate: NSObject, NSApplicationDelegate {
	// A provider, not a value: safeSave promotion renames the VM mid-run, and every action
	// here must target the live name. Only the (rebuilt-never) menu TITLES stay stale.
	private let vmName: () -> String
	private let presenter: WindowPresenter
	private let server: MachmanServer

	init(vmName: @escaping () -> String, presenter: WindowPresenter, server: MachmanServer) {
		self.vmName = vmName
		self.presenter = presenter
		self.server = server
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false   // closing the window leaves the VM running; the host stays
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		let name = vmName()
		guard presenter.isRunning?(name) ?? false else {
			server.stop()
			return .terminateNow
		}
		let alert = NSAlert()
		alert.messageText = "\(name) is running"
		alert.informativeText = "Quitting stops the VM. Ask the guest to shut down, "
			+ "stop it immediately, or cancel?"
		alert.addButton(withTitle: "Shut Down")
		alert.addButton(withTitle: "Force Stop")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			presenter.stopHandler?(name, .soft)
		case .alertSecondButtonReturn:
			presenter.stopHandler?(name, .force)
		default:
			break
		}
		return .terminateCancel
	}

	@objc func shutDown(_ sender: Any?) {
		presenter.stopHandler?(vmName(), .soft)
	}

	@objc func forceStop(_ sender: Any?) {
		presenter.stopHandler?(vmName(), .force)
	}
}
