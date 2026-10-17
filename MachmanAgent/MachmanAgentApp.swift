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

// The entry point. Under a test suite (the lab) the agent is a plain NSApplication with no
// SwiftUI scene: a MenuBarExtra makes an NSStatusItem even when it isn't inserted, and AppKit
// saves that item's visibility into the agent's preferences — the dev agent's own domain, as
// the lab agent shares its bundle id. Everywhere else it is the SwiftUI app below.
@main
enum MachmanAgentMain {
	@MainActor static func main() {
		if MachmanTestMode.isActive {
			MachmanAgentDelegate.runWithoutScenes()
		} else {
			MachmanAgentApp.main()
		}
	}
}

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
	// Test mode only: the lab's control socket, and the reason its last `quit` asked for.
	private static var labControl: LabControlServer?
	private static var labQuitReason: LabQuitReason?
	// Test mode only: the delegate of the scene-less run (NSApp holds its delegate weakly).
	private static var sceneless: MachmanAgentDelegate?

	// Test mode only: AppKit's run loop with this delegate and nothing else — no scene, no
	// status item, no window. Launch, quit and the lab's seams take the same paths as in the
	// SwiftUI app.
	static func runWithoutScenes() {
		let app = NSApplication.shared
		app.setActivationPolicy(.prohibited)
		let delegate = MachmanAgentDelegate()
		sceneless = delegate
		app.delegate = delegate
		app.run()
	}

	// Under a test suite the agent can never become active or show UI, even through a path
	// the prompts' routing (PromptAlert) missed; the banner is what the lab waits for.
	func applicationWillFinishLaunching(_ notification: Notification) {
		guard let lab = LabEnvironment.current else { return }
		NSApp.setActivationPolicy(.prohibited)
		MachmanLogger.log(.log, "test mode: agent under \(lab.suiteID); prompts answered from "
			+ (lab.answersPath ?? "their cancel buttons") + "; control "
			+ (lab.agentControlPath ?? "off") + "; no menu bar item")
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		Self.serveLabControl()
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
			let prompt = AgentPrompt.cannotStart(reason: MachmanError.userMessage(for: error))
			_ = PromptAlert.run(prompt.labPrompt, style: .critical)
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
			runInFront(prompt) == 0   // Replace
		}
		guard replace else {
			await client.disconnect()
			MachmanLogger.log(.log, "keeping the older daemon; exiting")
			NSApp.terminate(nil)
			return
		}
		MachmanLogger.log(.log, "replacing daemon \(running) with \(mine)")
		do {
			try await client.retire()
		} catch let error as MachmanError where error.code == .invalidState {
			// It runs work of its own that would die with it (E45): it stays, this one goes.
			await client.disconnect()
			MachmanLogger.log(.log, "the older daemon can't retire yet (\(error.message)); exiting")
			let refused = AgentPrompt.replaceRefused(reason: error.message)
			_ = await MainRunLoopCallout.run { runInFront(refused) }
			NSApp.terminate(nil)
			return
		} catch {
			// A dropped connection: the takeover below finds out whether it went.
		}
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
	// an LSUIElement app's alert can otherwise sit behind every window. The chosen button's
	// index; under a test suite, the lab's answer.
	private static func runInFront(_ prompt: AgentPrompt) -> Int {
		PromptAlert.run(prompt.labPrompt)
	}

	// Test mode only (MACHMAN_LAB_AGENT_CONTROL): what a lab test triggers in here that no
	// socket request reaches — a quit for a chosen reason, and the menu's items, enabled by
	// the menu's own rule. A second agent of the suite finds the path served: it goes on
	// without one.
	private static func serveLabControl() {
		guard let path = LabEnvironment.current?.agentControlPath else { return }
		do {
			labControl = try LabControlServer(path: path) { command in
				switch command {
				case .ping:
					return "ok"
				case .quit(let reason):
					// After the reply has left: a quit that goes through ends the process.
					labQuitReason = reason
					Task { @MainActor in
						try? await Task.sleep(for: .milliseconds(250))
						MainRunLoopCallout.post { NSApp.terminate(nil) }
					}
					return "ok"
				case .menu(let action, let vm):
					guard served else { return "error not serving" }
					switch Daemon.menuBar.performLab(action, vm: vm) {
					case .done: return "ok"
					case .disabled: return "disabled"
					case .noSuchVM: return "error no VM named \(vm)"
					}
				}
			}
		} catch {
			MachmanLogger.log(.log, "test mode: no lab control (\(error))")
		}
	}

	// VM windows come and go; the daemon lives in the menu bar.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard Self.served else { return .terminateNow }
		// A lab quit's reason stands in for the quit event's (test mode only), once.
		let lab = Self.labQuitReason.map(VMHostQuitReason.init(lab:))
		Self.labQuitReason = nil
		let reason = lab ?? VMHostQuitReason.current()
		let running = Daemon.api.runningVMNames
		let sessionHolders = Daemon.api.sessionHolders
		switch AgentQuitDecision.decide(
			reason: reason, runningVMs: running.count, holders: sessionHolders) {
		case .quit:
			Daemon.server.stop()
			return .terminateNow
		case .cancelQuietly:
			// Each VM's own window cancels the log out too and says what to do (V1), as does a
			// vmhost finishing work for the agent with no VM running (V15).
			let held = running.isEmpty
				? sessionHolders.map { "\($0.vm) \($0.activity)" }.joined(separator: ", ")
				: running.joined(separator: ", ") + " still running"
			MachmanLogger.log(.log, "\(reason) canceled: \(held)")
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
		case .askAboutWork(let holders):
			// The user's own quit, while the agent runs work no VM window knows of (E47).
			guard Self.runInFront(AgentPrompt.quitDuringWork(holders)) == 1 else {   // Quit Anyway
				return .terminateCancel
			}
			Daemon.server.stop()
			return .terminateNow
		case .ask(let work):
			return askAboutVMs(sender, stopping: work)
		}
	}

	// The user's own quit while VMs run. Each way of quitting also stops the work the agent
	// runs itself, so that is asked about after the choice (F10).
	private func askAboutVMs(
		_ sender: NSApplication, stopping work: [SessionHolder]
	) -> NSApplication.TerminateReply {
		// In front, where they can see it. Its buttons: leave them running, shut them down,
		// force stop them, Cancel.
		let choice = PromptAlert.run(AgentPrompt.vmsStillRunning.labPrompt)
		guard (0...2).contains(choice) else { return .terminateCancel }
		if !work.isEmpty,
			Self.runInFront(AgentPrompt.quitDuringWork(work)) != 1 {   // Quit Anyway
			return .terminateCancel
		}
		switch choice {
		case 0:
			Daemon.server.stop()
			return .terminateNow
		case 1:
			stopAllAndQuit(sender, soft: true)
		default:
			stopAllAndQuit(sender, soft: false)
		}
		return .terminateLater
	}

	private func stopAllAndQuit(_ app: NSApplication, soft: Bool) {
		Task { @MainActor in
			// Shut Down All ends the VMs whose vmhost still doesn't answer after the grace, as
			// a confirmed End Process would (K12): the choice already asked to stop them all.
			let left = await Daemon.api.stopAllHosted(
				softFirst: soft, graceSeconds: 30, endingUnanswered: soft)
			// Force Stop All: VMs whose vmhost didn't answer the force stop are ended only when
			// asked a second time (C9); otherwise they keep running, as with a plain quit.
			if !soft, !left.isEmpty, await MainRunLoopCallout.run({
				EndProcessPrompt.forQuit(leaving: left).runInFront()
			}) {
				for name in left {
					do {
						try await Daemon.api.endProcess(vm: name)
					} catch {
						MachmanLogger.log(.passiveError, "quit: couldn't end \(name)'s "
							+ "process (\(MachmanError.userMessage(for: error))) — leaving it")
					}
				}
			}
			Daemon.server.stop()
			app.reply(toApplicationShouldTerminate: true)
		}
	}
}
