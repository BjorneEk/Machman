//
//  VMHostPrompts.swift
//  MachmanCore
//
//  The vmhost's questions to the user, as values: the close prompt, the quit prompt and the
//  shutdown follow-up. WindowPresenter.present shows one as an alert and answers with the
//  chosen button's meaning; tests answer it instead, so every flow behind a prompt runs
//  without a window or a modal loop. Also here: why the vmhost is asked to quit, and when a
//  prompt lends a windowless host a Dock icon.
//

import Foundation
import AppKit
import MachmanAPI

// What a prompt's button means.
enum HostChoice: Equatable {
	case closeWindow
	case shutDown
	case forceStop
	case keepWaiting
	case quitAnyway
	case cancel
}

struct HostPrompt: Equatable {
	struct Button: Equatable {
		let choice: HostChoice
		let title: String
	}

	// The lab answers a prompt by this id (HostPrompt+Lab), whatever its wording says.
	let id: String
	let message: String
	let info: String
	// The first is the default (Return).
	let buttons: [Button]

	// The alert's answer by button position; anything else (an aborted modal) cancels.
	func choice(forButtonAt index: Int) -> HostChoice {
		buttons.indices.contains(index) ? buttons[index].choice : .cancel
	}

	// The button Esc presses where AppKit wouldn't pick it (it does for "Cancel"): a cancel
	// with its own title, never the default, which keeps Return.
	var escapeButton: Int? {
		buttons.indices.dropFirst().first {
			buttons[$0].choice == .cancel && buttons[$0].title != "Cancel"
		}
	}

	// The VM window's close button while its VM runs.
	static func closeWhileRunning(_ name: String) -> HostPrompt {
		HostPrompt(
			id: "vmhost.closeWhileRunning",
			message: "\(name) is running",
			info: "Close the window and leave the VM running, "
				+ "ask the guest to shut down, or stop it immediately?",
			buttons: [
				Button(choice: .closeWindow, title: "Close Window"),
				Button(choice: .shutDown, title: "Shut Down"),
				Button(choice: .forceStop, title: "Force Stop"),
				Button(choice: .cancel, title: "Cancel"),
			])
	}

	// Quitting the vmhost while its VM runs: the VM dies with the process, so no "leave it
	// running" option. A log out, restart or shut down is already cancelled when this shows
	// (decision 6), so that prompt says what to do instead, and "Shut Down VM" can't be read
	// as shutting down the Mac.
	static func quitWhileRunning(_ name: String, reason: VMHostQuitReason) -> HostPrompt {
		guard reason != .userQuit else {
			return HostPrompt(
				id: "vmhost.quitWhileRunning",
				message: "\(name) is running",
				info: "Quitting stops the VM: ask the guest to shut down, or stop it now.",
				buttons: [
					Button(choice: .shutDown, title: "Shut Down"),
					Button(choice: .forceStop, title: "Force Stop"),
					Button(choice: .cancel, title: "Cancel"),
				])
		}
		let (canceled, again) = reason.canceled
		return HostPrompt(
			id: "vmhost.sessionEndWhileRunning",
			message: "\(name) is still running",
			info: "\(canceled): shut the VM down, then \(again).",
			buttons: [
				Button(choice: .shutDown, title: "Shut Down VM"),
				Button(choice: .forceStop, title: "Force Stop VM"),
				Button(choice: .cancel, title: "Keep Running"),
			])
	}

	// A log out, restart or shut down met an operation the vmhost still finishes after its VM
	// stopped (E46): it was canceled, and waits for the operation, not for the user.
	static func sessionEndDuringWork(
		_ name: String, activity: String, reason: VMHostQuitReason
	) -> HostPrompt {
		let (canceled, again) = reason.canceled
		return HostPrompt(
			id: "vmhost.sessionEndDuringWork",
			message: "\(name) \(activity)",
			info: "\(canceled): wait for it to finish, then \(again).",
			buttons: [Button(choice: .cancel, title: "OK")])
	}

	// The user's own quit met such an operation (C24): quitting would end it, so it asks, and
	// the default keeps it.
	static func quitDuringWork(_ name: String, activity: String) -> HostPrompt {
		HostPrompt(
			id: "vmhost.quitDuringWork",
			message: "\(name) \(activity) \u{2014} quit anyway?",
			info: "Quitting now stops it.",
			buttons: [
				Button(choice: .cancel, title: "Cancel"),
				Button(choice: .quitAnyway, title: "Quit Anyway"),
			])
	}

	// What a vmhost's running operation has its VM doing, after its name: the words the
	// agent's own claims use.
	static func activity(of operation: OperationInfo) -> String {
		switch operation.kind {
		case OperationInfo.Kind.importDisk: return VMClaims.Kind.importingDisk.activity
		case OperationInfo.Kind.promoteDisk: return VMClaims.Kind.promotingDisk.activity
		case OperationInfo.Kind.kernelImport: return VMClaims.Kind.importingKernel.activity
		case OperationInfo.Kind.safeSave: return "is being saved as a new VM"
		default: return "is still busy"
		}
	}

	// A shutdown request the guest hasn't acted on within the grace period.
	static func notShutDownYet(_ name: String) -> HostPrompt {
		HostPrompt(
			id: "vmhost.notShutDownYet",
			message: "\(name) hasn’t shut down yet",
			info: "The guest hasn’t responded to the shutdown request.",
			buttons: [
				Button(choice: .keepWaiting, title: "Keep Waiting"),
				Button(choice: .forceStop, title: "Force Stop"),
			])
	}

	// The guest can't take a shutdown request (still starting, paused). Cancel is the
	// default: a force stop loses unsaved work in the guest.
	static func shutDownRefused(_ name: String) -> HostPrompt {
		HostPrompt(
			id: "vmhost.shutDownRefused",
			message: "\(name) can’t be asked to shut down",
			info: "The guest can’t take a shutdown request right now — force stop it instead?",
			buttons: [
				Button(choice: .cancel, title: "Cancel"),
				Button(choice: .forceStop, title: "Force Stop"),
			])
	}

	// reason: the engine's own sentence.
	static func forceStopFailed(_ name: String, reason: String) -> HostPrompt {
		HostPrompt(
			id: "vmhost.forceStopFailed",
			message: "\(name) couldn’t be stopped",
			info: reason,
			buttons: [Button(choice: .cancel, title: "OK")])
	}
}

// Why the vmhost (or the agent, AgentQuitDecision) is asked to quit: the quit Apple event's
// kAEQuitReason, which loginwindow sets for a log out, restart or shut down. ⌘Q and the
// Dock's Quit carry none.
public enum VMHostQuitReason: Equatable, Sendable {
	case userQuit
	case logOut
	case restart
	case shutDown

	init(appleEventCode code: OSType?) {
		switch code {
		case OSType(kAELogOut), OSType(kAEReallyLogOut):
			self = .logOut
		case OSType(kAEShowRestartDialog), OSType(kAERestart):
			self = .restart
		case OSType(kAEShowShutdownDialog), OSType(kAEShutDown):
			self = .shutDown
		default:
			self = .userQuit
		}
	}

	// How an alert says this session end was canceled, and what to do again: the canceled
	// thing as a noun, as macOS writes it (W6). The user's own quit reads as a log out.
	var canceled: (sentence: String, again: String) {
		switch self {
		case .logOut, .userQuit: return ("Logout was canceled", "log out again")
		case .restart: return ("Restart was canceled", "restart again")
		case .shutDown: return ("Shutdown was canceled", "shut down your Mac again")
		}
	}

	// Read while AppKit handles the quit event, i.e. inside applicationShouldTerminate.
	@MainActor
	public static func current() -> VMHostQuitReason {
		guard let event = NSAppleEventManager.shared().currentAppleEvent,
			event.eventID == AEEventID(kAEQuitApplication) else {
			return .userQuit
		}
		let keyword = AEKeyword(kAEQuitReason)
		let reason = event.attributeDescriptor(forKeyword: keyword)
			?? event.paramDescriptor(forKeyword: keyword)
		let code = reason.map { $0.typeCodeValue != 0 ? $0.typeCodeValue : $0.enumCodeValue }
		return VMHostQuitReason(appleEventCode: code)
	}
}
