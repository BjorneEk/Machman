//
//  Eventually.swift
//  MachmanTestSupport
//
//  Wait for main-actor state that an async hop settles (a view model's Task, a store's
//  event pump): polls `condition` until it holds or the timeout passes, returning the last
//  answer so the call site's #expect reports it. The default deadline is generous on
//  purpose: a condition that holds returns at its first true poll, so the deadline only
//  bounds a failure, and a loaded parallel run must never fail a test that was merely slow —
//  nor one whose main thread another test held meanwhile (WaitBudget, Q41).
//

import Foundation

@MainActor
public func eventually(
	timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool
) async -> Bool {
	var budget = WaitBudget(timeout, turn: .milliseconds(20))
	while !condition() {
		guard budget.lasts() else { return false }
		try? await Task.sleep(for: .milliseconds(10))
	}
	return true
}
