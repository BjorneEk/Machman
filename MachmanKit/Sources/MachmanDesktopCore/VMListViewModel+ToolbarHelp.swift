//
//  VMListViewModel+ToolbarHelp.swift
//  MachmanDesktopCore
//
//  What the toolbar's image-only controls say on hover and to VoiceOver (decision 7: a plain
//  Start follows the start policy). A toolbar item is named by the command it runs, in
//  Title Case, as the Run and View menus name it.
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMListViewModel {
	// The plain Start's name for the policy it follows; a Mac that is installing can't start.
	public func startHelp(_ vm: VMInfo) -> String {
		if isInstalling(vm) { return "Wait for the macOS install to finish" }
		let options = vm.startOptions()
		switch (options.openWindow, options.safe) {
		case (true, false): return "Start"
		case (false, false): return "Start Headless"
		case (true, true): return "Start Safe"
		case (false, true): return "Start Headless and Safe"
		}
	}

	// Down, the dimmed toggle shows what a start will do; running, it opens or closes the
	// VM's window, which never stops the VM.
	public static func windowToggleHelp(_ vm: VMInfo) -> String {
		guard vm.state == .running else {
			return vm.startOptions().openWindow
				? "The window opens when the VM starts" : "The VM starts without a window"
		}
		return vm.windowOpen ? "Close Window — the VM keeps running" : "Open Window"
	}
}
