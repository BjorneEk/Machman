//
//  ToastWording.swift
//  MachmanDesktopCore
//
//  The toasts' wording families (wording.md 8): one pattern per action, past tense, things
//  named in running-text case: “Renamed to “x”” for every rename (VM, disk, mount tag,
//  kernel tag), “Added <thing>” / “Removed <thing>” for every add and remove.
//

import Foundation
import MachmanAPI
import MachmanUI

enum ToastWording {
	static func renamed(to name: String) -> String {
		"Renamed to \u{201C}\(name)\u{201D}"
	}
}

extension DeviceKind {
	// The kind inside a sentence: common nouns in lower case (“Added keyboard”), names keep
	// their capitals (“Added Rosetta”, “Added Guest Setup”).
	var inlineLabel: String {
		switch self {
		case .rosetta, .guestSetup, .consoleLoginInstaller, .sshInstaller:
			return displayLabel
		default:
			return displayLabel.prefix(1).lowercased() + displayLabel.dropFirst()
		}
	}
}
