//
//  VMWindowAction.swift
//  MachmanUI
//
//  Which window item a VM offers (P27), shared by the desktop's View menu and picker and the
//  menu-bar agent: Open or Close Window while it runs WITH a display, nothing otherwise — a
//  VM without enabled graphics has no window to open, whatever its vmhost would do.
//

import Foundation
import MachmanAPI

public enum VMWindowAction: Sendable, Equatable {
	case open
	case close
}

extension VMInfo {
	// Whether the VM would boot with a display. nil devices = a pre-1.0.4 daemon, where
	// graphics were unconditional — treat as present.
	public var hasEnabledGraphics: Bool {
		guard let devices else { return true }
		return devices.contains { $0.kind == .graphics && $0.enabled }
	}

	public var windowAction: VMWindowAction? {
		guard state.isRunning, hasEnabledGraphics else { return nil }
		return windowOpen ? .close : .open
	}
}
