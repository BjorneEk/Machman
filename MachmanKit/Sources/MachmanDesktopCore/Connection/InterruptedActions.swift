//
//  InterruptedActions.swift
//  MachmanDesktopCore
//
//  The calls a lost connection cut off, said as the user's own actions: "starting Debian",
//  "deleting Alpine". Reads (lists, previews, phases) and the agent's own bookkeeping never
//  count — only something the user asked to happen, which may or may not have happened.
//

import Foundation
import MachmanAPI
import MachmanClient

enum InterruptedActions {
	// nil for a call whose loss changes nothing the user asked for.
	static func phrase(_ call: InterruptedCall) -> String? {
		let vm = call.vm ?? "a VM"
		switch call.method {
		case .hello, .hostCapabilities, .vmList, .vmGet, .hostOperations, .preview,
			.installPhase, .eventsSubscribe, .event, .daemonRetire:
			return nil
		case .vmCreate: return "creating a VM"
		case .vmDelete: return "deleting \(vm)"
		case .vmRename: return "renaming \(vm)"
		case .vmCopy: return "duplicating \(vm)"
		case .start: return "starting \(vm)"
		case .stop: return "stopping \(vm)"
		case .safeSave: return "saving \(vm) as a new VM"
		case .windowOpen: return "opening \(vm)’s window"
		case .windowClose: return "closing \(vm)’s window"
		case .diskImport: return "importing a disk into \(vm)"
		case .diskPromote: return "copying a disk into \(vm)"
		case .installStart: return "starting \(vm)’s macOS install"
		case .installCancel: return "canceling \(vm)’s macOS install"
		case .installRosetta: return "installing Rosetta"
		case .operationCancel: return "canceling an operation"
		default: return call.vm.map { "changing \($0)" } ?? "a change"
		}
	}

	// One sentence naming what to check, or nil when nothing the user asked for was cut off.
	static func message(_ calls: [InterruptedCall]) -> String? {
		var phrases: [String] = []
		for phrase in calls.compactMap(phrase) where !phrases.contains(phrase) {
			phrases.append(phrase)
		}
		switch phrases.count {
		case 0:
			return nil
		case 1:
			return "Check whether \(phrases[0]) finished."
		case 2:
			return "Check whether \(phrases[0]) and \(phrases[1]) finished."
		default:
			return "Check whether \(phrases[0]), \(phrases[1]) and \(phrases.count - 2) more "
				+ "finished."
		}
	}
}
