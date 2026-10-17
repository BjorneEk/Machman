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
//  VM that leaves the list — deleted here, or while the app was away — takes its state along.
//

import Foundation

@MainActor
public protocol VMKeyedState: AnyObject {
	// The VM is now called `new`.
	func renameVM(from old: String, to new: String)
	// Save as New VM: the run goes on as `new`, and `old` stays, stopped.
	func copyVM(from old: String, to new: String)
	// Every VM not in `kept` is gone.
	func forgetVMs(except kept: Set<String>)
}
