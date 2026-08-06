//
//  MachmandApp.swift
//  Machmand
//
//  The Machman daemon: a menu-bar agent (LSUIElement) that owns the VM engine, presents
//  console windows, and serves the MachmanControlling API over <dataDir>/machman.sock.
//  Machman-desktop, the CLI, and any non-Swift client are all just connections to it.
//

import SwiftUI
import Cocoa
import MachmanAPI
import MachmanCore

// The one engine instance for this process; the app delegate reaches it for quit handling.
// The router spawns one MachmanVMHost process per running VM and proxies to it.
@MainActor
enum Daemon {
	static let registry = VMRegistry()
	static let api = RoutingMachman(registry: registry, daemonVersion: version)
	static let server = MachmanServer(api: api, daemonVersion: version)

	static var version: String {
		(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
	}
}

@main
struct MachmandApp: App {
	@NSApplicationDelegateAdaptor(MachmandDelegate.self) var delegate
	@StateObject private var model: MenuBarModel

	init() {
		_model = StateObject(wrappedValue: MenuBarModel(api: Daemon.api))
	}

	var body: some Scene {
		MenuBarExtra("Machman", systemImage: "desktopcomputer") {
			MenuBarView(model: model)
		}
	}
}

@MainActor
final class MachmandDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		do {
			try Daemon.server.start()
		} catch {
			let alert = NSAlert()
			alert.messageText = "Machmand cannot start"
			alert.informativeText = "\(error)"
			alert.alertStyle = .critical
			alert.runModal()
			NSApp.terminate(nil)
			return
		}
		// VMs from a previous daemon run live on in their vmhost processes — take them back.
		Task {
			await Daemon.api.adoptExistingHosts()
		}
	}

	// Console windows come and go; the daemon lives in the menu bar.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard Daemon.api.hasHostedVMs else {
			Daemon.server.stop()
			return .terminateNow
		}

		let alert = NSAlert()
		alert.messageText = "VMs are still running"
		alert.informativeText = "Running VMs live in their own processes: you can quit and "
			+ "leave them running (the next Machmand re-adopts them), ask the guests to shut "
			+ "down (force-stopped after 30 seconds), or force stop everything now."
		alert.addButton(withTitle: "Quit, Leave VMs Running")
		alert.addButton(withTitle: "Shut Down All & Quit")
		alert.addButton(withTitle: "Force Stop All & Quit")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			Daemon.server.stop()
			return .terminateNow
		case .alertSecondButtonReturn:
			stopAllAndQuit(sender, soft: true)
		case .alertThirdButtonReturn:
			stopAllAndQuit(sender, soft: false)
		default:
			return .terminateCancel
		}
		return .terminateLater
	}

	private func stopAllAndQuit(_ app: NSApplication, soft: Bool) {
		Task { @MainActor in
			await Daemon.api.stopAllHosted(softFirst: soft, graceSeconds: 30)
			Daemon.server.stop()
			app.reply(toApplicationShouldTerminate: true)
		}
	}
}
