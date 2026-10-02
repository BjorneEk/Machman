//
//  VMListViewModel+EngineLog.swift
//  MachmanDesktopCore
//
//  How an engine warning or error reads as a toast and an Activity entry's key: "<VM>: <the
//  engine's sentence>". The engine's boot-time warnings leave the VM out for that (W3), but
//  an older daemon's, and refusals relayed as error events, already start with it — those
//  stand as they are, so a toast names the VM once (wording rule 5).
//

import Foundation

extension VMListViewModel {
	// "Debian has no display device — started headless" (a 1.0.12 daemon) stays as it is;
	// "It has no display, so it started headless." reads "Debian: It has no display, …". The
	// name must end on a word boundary: "Deb" does not start "Debian x".
	public static func engineLogText(vm: String?, message: String) -> String {
		guard let vm, !vm.isEmpty else { return message }
		if message.hasPrefix(vm) {
			let rest = message.dropFirst(vm.count)
			if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { return message }
		}
		return "\(vm): \(message)"
	}
}
