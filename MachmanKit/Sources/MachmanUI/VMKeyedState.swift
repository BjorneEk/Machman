//
//  VMKeyedState.swift
//  MachmanUI
//
//  Client-side state keyed by a VM's name (PR24): live terminals, canvas layouts, preview
//  frames, install phases, the list announcer's memory, per-port terminal profiles. A name
//  changes hands three ways, and the view model walks every store through each in one place
//  (VMListViewModel.keyedState), so a store added later can't be forgotten by one of them:
//  a rename moves the state; Save as New VM continues the run under a new name while the
//  original stays, and each store says whether its state goes with the run or is copied; a
//  VM that leaves the list takes its state along. A store whose state should outlive a VM's
//  absence from one list (persisted choices: an external library may sleep, a config fail to
//  load for a moment) forgets nothing on absence and goes by vmDeleted and listed instead.
//

import Foundation
import MachmanAPI

@MainActor
public protocol VMKeyedState: AnyObject {
	// The VM is now called `new`.
	func renameVM(from old: String, to new: String)
	// Save as New VM: the run goes on as `new`, and `old` stays, stopped.
	func copyVM(from old: String, to new: String)
	// Every VM not in `kept` has left the list.
	func forgetVMs(except kept: Set<String>)
	// This desktop's delete of the VM went through.
	func vmDeleted(_ vm: String)
	// A list landed: each listed VM as the agent reports it (its created date tells it from a
	// new VM under the same name).
	func listed(_ vms: [VMInfo])
}

extension VMKeyedState {
	// A store that forgets on absence needs neither: the deleted VM leaves the next list.
	public func vmDeleted(_ vm: String) {}
	public func listed(_ vms: [VMInfo]) {}
}
