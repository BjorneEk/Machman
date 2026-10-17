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

// Which VM a name's kept state belongs to, for a store that outlives absence: each name's
// created date, learned from the first list that shows it, tells a new VM under that name
// from the one the state is for. Persisted by its store as a plain name → date dictionary.
public struct VMOwnerDates: Equatable, Sendable {
	public private(set) var dates: [String: Date]

	public init(_ dates: [String: Date] = [:]) {
		self.dates = dates
	}

	// A list landed and `owners` hold state. Returns the names now carried by another VM —
	// their state is stale and their date gone — and whether any date was learned or dropped.
	public mutating func reconcile(_ vms: [VMInfo], owners: Set<String>)
		-> (stale: [String], changed: Bool) {
		var stale: [String] = []
		var changed = false
		for vm in vms where owners.contains(vm.name) {
			if let recorded = dates[vm.name] {
				guard !Self.sameVM(recorded, vm.created) else { continue }
				dates[vm.name] = nil
				stale.append(vm.name)
			} else {
				dates[vm.name] = vm.created
			}
			changed = true
		}
		return (stale, changed)
	}

	// A rename keeps the VM, so its date goes along.
	public mutating func move(from old: String, to new: String) {
		dates[new] = dates.removeValue(forKey: old)
	}

	// True when there was a date to forget.
	@discardableResult
	public mutating func forget(_ vm: String) -> Bool {
		dates.removeValue(forKey: vm) != nil
	}

	// The same VM, as far as a created date says (a millisecond for the encoders' rounding).
	private static func sameVM(_ a: Date, _ b: Date) -> Bool {
		abs(a.timeIntervalSince(b)) < 0.001
	}
}
