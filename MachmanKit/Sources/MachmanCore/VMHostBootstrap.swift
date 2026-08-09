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
	// Never returns: hands the thread to NSApplication.run().
	@MainActor
	public static func run(
		dataDir: String, vmName: String, socketPath: String, daemonVersion: String,
		autostart: Bool = false
	) -> Never {
		machmanVMDir = dataDir

		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)

		let registry = VMRegistry(only: vmName)
		// The console flips this process to a real app (Dock icon, menus) while a window is
		// open — a per-VM app the user can ⌘-Tab to — and back to accessory when it closes.
		registry.presenter.managesActivationPolicy = true
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

		let delegate = VMHostAppDelegate(
			vmName: vmName, presenter: registry.presenter, server: server)
		Self.appDelegate = delegate   // app.delegate is unowned — something must own it
		app.delegate = delegate
		app.mainMenu = buildMainMenu(vmName: vmName, delegate: delegate)

		let lifecycle = Lifecycle()
		// Exit when the VM stops (after having run). The idle backstop covers a spawn whose
		// start never happened — e.g. the daemon died between spawn and forward.
		Task { @MainActor in
			let stream = registry.events.stream()
			for await event in stream {
				guard case .stateChanged(let vm, let state) = event, vm == vmName else {
					continue
				}
				if state.isRunning {
					lifecycle.hadRunning = true
				}
				if state == .stopped, lifecycle.hadRunning {
					try? await Task.sleep(for: .milliseconds(300))   // let replies/events flush
					server.stop()
					exit(0)
				}
			}
		}
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(180))
			if !lifecycle.hadRunning {
				server.stop()
				exit(0)
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
						vm: vmName, options: StartOptions(openConsole: policy.windowed))
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
	private final class Lifecycle {
		var hadRunning = false
	}

	@MainActor
	private static var appDelegate: VMHostAppDelegate?

	// Icon-less on purpose, and no Edit/Window menus — the keyboard belongs to the guest.
	// macOS may render the bold app-menu title from the bundle's display name; the items and
	// the window title carry the VM name regardless.
	@MainActor
	private static func buildMainMenu(vmName: String, delegate: VMHostAppDelegate) -> NSMenu {
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

// Quit semantics for a process that IS its VM: quitting while running has no "leave it
// running" option (that would be a lie — the VM dies with the host), so the prompt offers
// the two stop modes and Cancel, always answers .terminateCancel, and lets the existing
// stopped→exit(0) watcher stay the single teardown path.
@MainActor
final class VMHostAppDelegate: NSObject, NSApplicationDelegate {
	private let vmName: String
	private let presenter: ConsolePresenter
	private let server: MachmanServer

	init(vmName: String, presenter: ConsolePresenter, server: MachmanServer) {
		self.vmName = vmName
		self.presenter = presenter
		self.server = server
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false   // closing the console leaves the VM running; the host stays
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard presenter.isRunning?(vmName) ?? false else {
			server.stop()
			return .terminateNow
		}
		let alert = NSAlert()
		alert.messageText = "\(vmName) is running"
		alert.informativeText = "Quitting stops the VM. Ask the guest to shut down, "
			+ "stop it immediately, or cancel?"
		alert.addButton(withTitle: "Shut Down")
		alert.addButton(withTitle: "Force Stop")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			presenter.stopHandler?(vmName, .soft)
		case .alertSecondButtonReturn:
			presenter.stopHandler?(vmName, .force)
		default:
			break
		}
		return .terminateCancel
	}

	@objc func shutDown(_ sender: Any?) {
		presenter.stopHandler?(vmName, .soft)
	}

	@objc func forceStop(_ sender: Any?) {
		presenter.stopHandler?(vmName, .force)
	}
}
