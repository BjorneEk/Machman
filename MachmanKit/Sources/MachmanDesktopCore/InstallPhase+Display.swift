//
//  InstallPhase+Display.swift
//  MachmanDesktopCore
//
//  A running macOS install's phase as people read it, the same on the canvas banner and on
//  its corner card.
//

import Foundation
import MachmanAPI

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
}
