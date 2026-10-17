//
//  InstallPhase+Display.swift
//  MachmanDesktopCore
//
//  A running macOS install's phase as people read it, the same on the canvas banner and on
//  its corner card, and what VoiceOver hears as that card leaves (H56, review F16).
//

import Foundation
import MachmanAPI
import MachmanUI

extension InstallPhase {
	// The phase as the banner and its card say it: "Downloading macOS 15.4…".
	public var displayLabel: String {
		let version = self.version.map { " macOS \($0)" } ?? ""
		switch kind {
		case .resolving: return "Resolving\(version)…"
		case .downloading: return "Downloading\(version)…"
		default: return "Installing\(version)…"
		}
	}

	// The corner card a running install shows.
	public static func cardTitle(vm: String) -> String { "\(vm) — Installing macOS" }

	// The card shows only while the install runs; an ended one simply leaves (H56, review F16).
	public var isRunning: Bool {
		kind == .resolving || kind == .downloading || kind == .installing
	}

	// What VoiceOver hears as an install's card leaves: its outcome, once, as an operation's
	// finished card says it ("<title>: <outcome>"); a failure or an interruption urgently.
	// A phase that goes away (the VM gone, a reconnect starting the phases over) or was
	// never running here says nothing.
	public static func announcements(
		from old: [String: InstallPhase], to new: [String: InstallPhase]
	) -> [ToastAnnouncement] {
		new.keys.sorted().compactMap { vm in
			guard let phase = new[vm], old[vm]?.isRunning == true, !phase.isRunning,
				let outcome = phase.outcome else { return nil }
			return ToastAnnouncement(
				text: "\(cardTitle(vm: vm)): \(outcome)",
				urgent: phase.kind == .failed || phase.kind == .interrupted)
		}
	}

	// An ended install's outcome; a cancel returns the phase to the VM's own (idle).
	private var outcome: String? {
		switch kind {
		case .installed: return "Installed"
		case .failed: return message.map { "Failed — \($0)" } ?? "Failed"
		case .interrupted: return "Interrupted"
		case .idle: return "Canceled"
		case .resolving, .downloading, .installing: return nil
		}
	}
}
