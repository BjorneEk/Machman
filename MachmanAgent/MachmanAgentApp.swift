//
//  MachmanAgentApp.swift
//  MachmanAgent
//
//  The Machman daemon: a menu-bar agent (LSUIElement) that owns the VM engine, presents
//  console windows, and serves the MachmanControlling API over <dataDir>/machman.sock.
//  MachmanDesktop, the CLI, and any non-Swift client are all just connections to it.
//

import SwiftUI
import MachmanUI
import Cocoa
import MachmanAPI
import MachmanCore
import MachmanClient

// The one engine instance for this process; the app delegate reaches it for quit handling.
// The router spawns one MachmanVMHost process per running VM and proxies to it.
@MainActor
enum Daemon {
	static let registry = VMRegistry()
	static let api: RoutingMachman = {
		let launchAgents = LaunchAgentManager.live()
		if launchAgents == nil {
			MachmanLogger.log(.passiveError,
				"MachmanVMHost.app not found; autostart agents will not be written")
		}
		return RoutingMachman(
			registry: registry, daemonVersion: version, launchAgents: launchAgents)
	}()
	static let server = MachmanServer(api: api, daemonVersion: version)

	static var version: String {
		(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
	}
}

@main
struct MachmanAgentApp: App {
	@NSApplicationDelegateAdaptor(MachmanAgentDelegate.self) var delegate
	@StateObject private var model: MenuBarModel

	init() {
		_model = StateObject(wrappedValue: MenuBarModel(api: Daemon.api))
	}

	var body: some Scene {
		MenuBarExtra("Machman", systemImage: MachmanSymbols.menuBarExtra) {
			MenuBarView(model: model)
		}
	}
}

@MainActor
final class MachmanAgentDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		do {
			try Daemon.server.start()
		} catch UDSError.alreadyRunning(let path) {
			// A daemon already serves this suite. Same-or-newer build: step aside quietly (the
			// socket is the mutex, and the desktop auto-launches copies whenever it can't
			// connect). An OLDER build still serving is the stale-daemon hazard — offer to
			// replace it, leaving its VMs running.
			Task { @MainActor in
				await Self.considerReplacingOlderDaemon(at: path)
			}
			return
		} catch {
			// Log FIRST: this app is LSUIElement, so an NSAlert can end up behind everything
			// with no Dock icon to click. That failure mode looks exactly like a hung daemon —
			// present in Activity Monitor, no menu bar item, nothing answering the socket.
			MachmanLogger.log(.interactionError, "cannot start: \(error)")
			NSApp.setActivationPolicy(.regular)
			NSApp.activate(ignoringOtherApps: true)
			let alert = NSAlert()
			alert.messageText = "Machman Agent cannot start"
			alert.informativeText = "\(error)"
			alert.alertStyle = .critical
			alert.runModal()
			NSApp.terminate(nil)
			return
		}
		Self.beginServing()
	}

	// Everything that follows a successful server.start(): the retire hook (exit
	// leave-VMs-running, bypassing the quit prompt) and startup reconciliation.
	private static func beginServing() {
		Daemon.api.onRetire = {
			MachmanLogger.log(.log, "retired; exiting and leaving vmhosts running")
			Daemon.server.stop()
			exit(0)
		}
		// VMs from a previous daemon run live on in their vmhost processes — take them back.
		// Agents heal after adoption so bootout gating sees every live host.
		Task {
			await Daemon.api.adoptExistingHosts()
			Daemon.api.healLaunchAgents()
			Daemon.registry.sweepCopyStaging()
		}
	}

	// The launch-side skew prompt: a newly launched MachmanAgent that finds an OLDER build serving
	// offers to retire it. Same-or-newer (or unreachable): today's silent concede.
	private static func considerReplacingOlderDaemon(at path: String) async {
		let mine = Daemon.version
		guard let client = try? await RemoteMachman(
			socketPath: path, clientName: "machman-agent-takeover") else {
			MachmanLogger.log(.log, "another daemon is already serving \(path); exiting")
			NSApp.terminate(nil)
			return
		}
		let running = client.hello.daemonVersion
		guard MachmanVersion.isOlder(running, than: mine) else {
			await client.disconnect()
			MachmanLogger.log(.log,
				"another daemon (\(running)) is already serving \(path); exiting")
			NSApp.terminate(nil)
			return
		}
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		let alert = NSAlert()
		alert.messageText = "An older Machman Agent is still running"
		alert.informativeText = "The running daemon is version \(running); this one is "
			+ "\(mine). Replace it? Its VMs keep running and are re-adopted."
		alert.addButton(withTitle: "Replace")
		alert.addButton(withTitle: "Cancel")
		let replace = alert.runModal() == .alertFirstButtonReturn
		NSApp.setActivationPolicy(.accessory)
		guard replace else {
			await client.disconnect()
			MachmanLogger.log(.log, "keeping the older daemon; exiting")
			NSApp.terminate(nil)
			return
		}
		MachmanLogger.log(.log, "replacing daemon \(running) with \(mine)")
		try? await client.retire()
		await client.disconnect()
		// Take the socket over as soon as the old daemon releases it.
		for _ in 0..<25 {
			try? await Task.sleep(for: .milliseconds(200))
			do {
				try Daemon.server.start()
				beginServing()
				return
			} catch UDSError.alreadyRunning {
				continue
			} catch {
				break
			}
		}
		MachmanLogger.log(.passiveError, "takeover failed: the old daemon did not release "
			+ "\(path); exiting")
		NSApp.terminate(nil)
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
			+ "leave them running (the next Machman Agent re-adopts them), ask the guests to shut "
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
