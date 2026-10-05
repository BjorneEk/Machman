//
//  TFWait.swift
//  MachmanLabTests
//
//  Bounded polls for the engine rows: a condition, a VM's listed entry, a state. Every wait
//  has a deadline and names what it waited for; none blocks a thread (sleeps suspend).
//

import Foundation
import MachmanAPI

enum TFWait {
	/// Polls `check` every `every` until it holds; throws TFError.timeout naming `what`.
	static func until(
		_ what: String, timeout: Duration, every: Duration = .milliseconds(200),
		_ check: () async throws -> Bool
	) async throws {
		let deadline = ContinuousClock.now + timeout
		while true {
			if try await check() { return }
			if ContinuousClock.now >= deadline { throw TFError.timeout(what) }
			try await Task.sleep(for: every)
		}
	}

	/// The VM's listed entry once `match` holds for it (a missing entry never matches).
	@discardableResult
	static func vm(
		_ api: MachmanControlling, _ name: String, _ what: String, timeout: Duration,
		every: Duration = .milliseconds(200), _ match: (VMInfo) -> Bool
	) async throws -> VMInfo {
		let deadline = ContinuousClock.now + timeout
		var last = "not listed"
		while true {
			if let info = try await api.listVMs().first(where: { $0.name == name }) {
				if match(info) { return info }
				let stalled = info.unresponsive.map(String.init) ?? "nil"
				last = "\(info.state.rawValue), unresponsive \(stalled)"
			}
			if ContinuousClock.now >= deadline {
				throw TFError.timeout("\(name) to be \(what) (last \(last))")
			}
			try await Task.sleep(for: every)
		}
	}

	@discardableResult
	static func state(
		_ api: MachmanControlling, _ name: String, _ state: VMState, timeout: Duration
	) async throws -> VMInfo {
		try await vm(api, name, state.rawValue, timeout: timeout) { $0.state == state }
	}
}
