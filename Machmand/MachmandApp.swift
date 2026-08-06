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
		}
	}

	// Console windows come and go; the daemon lives in the menu bar.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		let running = Daemon.registry.list().filter { $0.state.isRunning }
		guard !running.isEmpty else {
			Daemon.server.stop()
			return .terminateNow
		}

		let alert = NSAlert()
		alert.messageText = running.count == 1
			? "\(running[0].name) is still running"
			: "\(running.count) VMs are still running"
		alert.informativeText = "Ask the guests to shut down (anything still running after "
			+ "30 seconds is force-stopped), force stop everything now, or cancel."
		alert.addButton(withTitle: "Shut Down All & Quit")
		alert.addButton(withTitle: "Force Stop All & Quit")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			stopAllAndQuit(sender, running, soft: true)
		case .alertSecondButtonReturn:
			stopAllAndQuit(sender, running, soft: false)
		default:
			return .terminateCancel
		}
		return .terminateLater
	}

	private func stopAllAndQuit(_ app: NSApplication, _ running: [VirtualMachine], soft: Bool) {
		Task { @MainActor in
			if soft {
				for vm in running {
					try? await Daemon.registry.stop(vm, mode: .soft)
				}
				let deadline = Date().addingTimeInterval(30)
				while Date() < deadline,
					Daemon.registry.list().contains(where: { $0.state.isRunning }) {
					try? await Task.sleep(for: .milliseconds(500))
				}
			}
			for vm in Daemon.registry.list() where vm.state.isRunning {
				try? await Daemon.registry.stop(vm, mode: .force)
			}
			Daemon.server.stop()
			app.reply(toApplicationShouldTerminate: true)
		}
	}
}
