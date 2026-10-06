//
//  HostPrompt+Lab.swift
//  MachmanCore
//
//  The vmhost's prompts as the lab answers them (LabAnswers): by the stable id each factory
//  in VMHostPrompts.swift sets, so a reworded or re-buttoned prompt keeps the answers keyed
//  on it.
//

import Foundation
import MachmanAPI

extension HostPrompt {
	var labPrompt: LabPrompt {
		LabPrompt(
			id: id, message: message, info: info, buttons: buttons.map(\.title),
			cancelIndex: buttons.firstIndex { $0.choice == .cancel })
	}
}
