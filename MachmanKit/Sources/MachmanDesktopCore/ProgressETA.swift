//
//  ProgressETA.swift
//  MachmanDesktopCore
//
//  ETA is consumer math (the daemon sends bytes, not times): the rate so far over what is
//  left, nil until there is a rate to go on. Operations and macOS install downloads share it.
//

import Foundation
import MachmanAPI

public enum ProgressETA {
	public static func seconds(
		done: Int64?, total: Int64?, since start: Date?, now: Date = Date()
	) -> Double? {
		guard let done, let total, let start, done > 0, total > done else { return nil }
		let elapsed = now.timeIntervalSince(start)
		guard elapsed > 1 else { return nil }
		return Double(total - done) / (Double(done) / elapsed)
	}
}

extension OperationInfo {
	// Only a running operation has one.
	public func etaSeconds(now: Date = Date()) -> Double? {
		guard state == State.running else { return nil }
		return ProgressETA.seconds(
			done: completedBytes, total: totalBytes, since: startedAt, now: now)
	}
}

extension InstallPhase {
	// Only the download has one; installing reports a fraction, not bytes over time.
	public func etaSeconds(now: Date = Date()) -> Double? {
		guard kind == .downloading else { return nil }
		return ProgressETA.seconds(
			done: progress?.completedBytes, total: progress?.totalBytes,
			since: downloadStartedAt, now: now)
	}
}
