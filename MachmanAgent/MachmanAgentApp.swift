//
//  MachmanAgentApp.swift
//  MachmanAgent
//
//  The Machman daemon: a menu-bar agent (LSUIElement) that owns the VM registry, spawns and
//  supervises one MachmanVMHost process per running VM (each presents its own VM's windows),
//  and serves the MachmanControlling API over $TMPDIR/<suite>/machman.sock. MachmanDesktop
//  and any non-Swift client (scripts/machman-smoke.py) are just connections to it.
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
			registry: registry, daemonVersion: version, launchAgents: launchAgents,
			sshHostConfig: SSHHostConfigWriter())
	}()
	static let server = MachmanServer(api: api, daemonVersion: version)
	// The menu's model, built at launch; it lists nothing until beginServing begins it (V9).
	static let menuBar = MenuBarModel(api: api)

	static var version: String {
		(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
	}
}

@main
struct MachmanAgentApp: App {
	@NSApplicationDelegateAdaptor(MachmanAgentDelegate.self) var delegate
	@StateObject private var model: MenuBarModel

	init() {
		_model = StateObject(wrappedValue: Daemon.menuBar)
	}

	var body: some Scene {
		MenuBarExtra("Machman", systemImage: MachmanSymbols.menuBarExtra) {
			MenuBarView(model: model)
		}
	}
}

@MainActor
final class MachmanAgentDelegate: NSObject, NSApplicationDelegate {
	// Whether this process ever served the socket (V9). One that stepped aside for another
	// agent quits at once: its engine never ran, so it has no VMs to ask about.
	private static var served = false

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
			alert.messageText = "Machman Agent can’t start"
			alert.informativeText = MachmanError.userMessage(for: error)
			alert.alertStyle = .critical
			alert.runModal()
			NSApp.terminate(nil)
			return
		}
		Self.beginServing()
	}

	// Everything that follows a successful server.start(): the retire hook (exit
	// leave-VMs-running, bypassing the quit prompt), startup reconciliation and the menu's
	// list.
	private static func beginServing() {
		served = true
		Daemon.api.onRetire = {
			MachmanLogger.log(.log, "retired; exiting and leaving vmhosts running")
			Daemon.server.stop()
			exit(0)
		}
		// VMs from a previous daemon run live on in their vmhost processes — take them back.
		// The shadow sweep runs strictly AFTER adoption: adoption is what re-hosts a
		// surviving safe vmhost, and only then can a run root be matched to its socket peer
		// (everything unmatched is garbage). Agents heal after adoption too, so bootout
		// gating sees every live host. The server parks requests until all of it is done:
		// before adoption a surviving vmhost's VM lists as stopped, so an early vm.stop
		// would "succeed" doing nothing and an early vm.delete would remove the directory
		// under a live guest (hello and daemon.retire still answer — see holdRequests).
		Daemon.server.holdRequests(until: Task {
			await Daemon.api.adoptExistingHosts()
			Daemon.api.sweepSafeRuns()
			Daemon.api.sweepStoppedVMLeftovers()
			Daemon.api.storeCollisionAliases()
			Daemon.api.healLaunchAgents()
			Daemon.registry.sweepCopyStaging()
		})
		Daemon.menuBar.begin()
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
		// From a run-loop callout, never a modal inside this main-actor Task (which would hold
		// every other main-actor job behind the alert).
		let prompt = AgentPrompt.replaceOlder(running: running, mine: mine)
		let replace = await MainRunLoopCallout.run {
			runInFront(prompt) == .alertFirstButtonReturn
		}
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

	// Lends the menu-bar agent a Dock icon and brings the prompt to the front while it shows:
	// an LSUIElement app's alert can otherwise sit behind every window.
	private static func runInFront(_ prompt: AgentPrompt) -> NSApplication.ModalResponse {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		defer { NSApp.setActivationPolicy(.accessory) }
		let alert = NSAlert()
		alert.messageText = prompt.message
		alert.informativeText = prompt.info
		for title in prompt.buttons {
			alert.addButton(withTitle: title)
		}
		return alert.runModal()
	}

	// VM windows come and go; the daemon lives in the menu bar.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard Self.served else { return .terminateNow }
		let reason = VMHostQuitReason.current()
		let running = Daemon.api.runningVMNames
		switch AgentQuitDecision.decide(
			reason: reason, runningVMs: running.count, holders: Daemon.api.sessionHolders) {
		case .quit:
			Daemon.server.stop()
			return .terminateNow
		case .cancelQuietly:
			// Each VM's own window cancels the log out too and says what to do (V1).
			MachmanLogger.log(.log,
				"\(reason) canceled: \(running.joined(separator: ", ")) still running")
			return .terminateCancel
		case .cancelAndExplain(let holders):
			// No VM window will say why (V10). The alert comes after this reply: the log out
			// waits on the reply, never on the alert.
			MachmanLogger.log(.log, "\(reason) canceled: "
				+ holders.map { "\($0.vm) \($0.activity)" }.joined(separator: ", "))
			let prompt = AgentPrompt.sessionEndHeld(reason: reason, holders: holders)
			Task { @MainActor in
				_ = await MainRunLoopCallout.run { Self.runInFront(prompt) }
			}
			return .terminateCancel
		case .ask:
			break
		}

		// The user's own quit: in front, where they can see it.
		NSApp.activate(ignoringOtherApps: true)
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
