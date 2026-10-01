//
//  RetryBackoff.swift
//  MachmanDesktopCore
//
//  The waits between a store's retries of a read that failed: short at first, then settling
//  on the last delay for as long as the failure lasts. A success resets it.
//

import Foundation

public struct RetryBackoff {
	public static let standardDelays: [Duration] = [
		.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30),
	]

	private let delays: [Duration]
	private var index = 0

	public init(delays: [Duration] = RetryBackoff.standardDelays) {
		self.delays = delays.isEmpty ? RetryBackoff.standardDelays : delays
	}

	// The next wait; the last one repeats.
	public mutating func next() -> Duration {
		let delay = delays[min(index, delays.count - 1)]
		index += 1
		return delay
	}

	public mutating func reset() {
		index = 0
	}
}
