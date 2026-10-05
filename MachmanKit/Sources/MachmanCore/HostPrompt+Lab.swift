//
//  HostPrompt+Lab.swift
//  MachmanCore
//
//  The vmhost's prompts as the lab answers them (LabAnswers): each needs a stable id for the
//  answers file. HostPrompt carries none of its own yet, so the id is read off the prompt's
//  buttons, which tell every factory in VMHostPrompts.swift apart; VMHostTestModeTests pins
//  the mapping, so a reworded or re-buttoned prompt fails there instead of silently moving
//  its answers. (When HostPrompt gains an id, this reads it instead.)
//

import Foundation
import MachmanAPI

extension HostPrompt {
	var labID: String {
		let shape = buttons.map(\.choice)
		switch shape {
		case [.closeWindow, .shutDown, .forceStop, .cancel]:
			return "vmhost.closeWhileRunning"
		case [.shutDown, .forceStop, .cancel]:
			// The user's own quit says Shut Down; a log out, restart or shut down says
			// Shut Down VM (it can't be read as shutting down the Mac).
			return buttons[0].title == "Shut Down VM"
				? "vmhost.sessionEndWhileRunning" : "vmhost.quitWhileRunning"
		case [.keepWaiting, .forceStop]:
			return "vmhost.notShutDownYet"
		case [.cancel, .forceStop]:
			return "vmhost.shutDownRefused"
		case [.cancel]:
			return "vmhost.forceStopFailed"
		default:
			return "vmhost.unknown"
		}
	}

	var labPrompt: LabPrompt {
		LabPrompt(
			id: labID, message: message, info: info, buttons: buttons.map(\.title),
			cancelIndex: buttons.firstIndex { $0.choice == .cancel })
	}
}
