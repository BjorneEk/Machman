//
//  RestartToUpdate.swift
//  MachmanUI
//
//  E22 (decision 9): a VM still run by a vmhost older than the daemon — one that outlived an
//  update of the app — has its setting changes refused until it restarts. The one sentence
//  every client shows for it, here so the desktop's inspector and the menu-bar agent can't
//  drift (the StartIntent precedent).
//

import Foundation
import MachmanAPI

extension VMInfo {
	// The sentence, or nil while the VM's vmhost is current (or the daemon predates 1.0.12).
	public var restartToUpdate: String? {
		outdatedHost == true ? "Restart this VM to finish updating" : nil
	}
}
