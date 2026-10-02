//
//  Subprocess.swift
//  MachmanTestSupport
//
//  Runs a child process to its end without holding a Swift concurrency thread. Launching,
//  reading and waiting block, and the cooperative pool has one thread per core: sync tests
//  that spawned shells in a burst starved every actor- and Task-based test beside them past
//  its deadlines (about one full run in four flaked). Here the blocking part runs on a
//  thread of its own while the caller suspends, and the children run one at a time, so the
//  parallel suite never meets a spawn burst either.
//

import Foundation

public enum Subprocess {
	public struct Result: Sendable {
		public let status: Int32
		public let output: String   // stdout and stderr, merged
	}

	// One child at a time, suite-wide. A fork copies the parent's descriptors into the
	// child until it execs, so every spawn briefly keeps sockets other tests just closed.
	private static let gate = AsyncGate(limit: 1)

	// `executable` with `arguments`, stdin /dev/null. A child still running after `timeout`
	// is terminated: a probe waiting on something never coming fails, never hangs the run.
	public static func run(
		_ executable: String, _ arguments: [String] = [],
		environment: [String: String]? = nil, directory: URL? = nil,
		timeout: TimeInterval = 60
	) async throws -> Result {
		await gate.enter()
		do {
			let result = try await runOffPool(
				executable, arguments, environment: environment, directory: directory,
				timeout: timeout)
			await gate.leave()
			return result
		} catch {
			await gate.leave()
			throw error
		}
	}

	private static func runOffPool(
		_ executable: String, _ arguments: [String], environment: [String: String]?,
		directory: URL?, timeout: TimeInterval
	) async throws -> Result {
		try await withCheckedThrowingContinuation { continuation in
			Thread.detachNewThread {
				let process = Process()
				process.executableURL = URL(fileURLWithPath: executable)
				process.arguments = arguments
				if let environment { process.environment = environment }
				if let directory { process.currentDirectoryURL = directory }
				process.standardInput = FileHandle.nullDevice
				let pipe = Pipe()
				process.standardOutput = pipe
				process.standardError = pipe
				do {
					try process.run()
				} catch {
					continuation.resume(throwing: error)
					return
				}
				DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
					if process.isRunning { process.terminate() }
				}
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				continuation.resume(returning: Result(
					status: process.terminationStatus,
					output: String(decoding: data, as: UTF8.self)))
			}
		}
	}
}

// At most `limit` holders at once; the rest suspend in arrival order, holding no thread.
actor AsyncGate {
	private let limit: Int
	private var holders = 0
	private var waiting: [CheckedContinuation<Void, Never>] = []

	init(limit: Int) { self.limit = limit }

	func enter() async {
		if holders < limit {
			holders += 1
			return
		}
		await withCheckedContinuation { waiting.append($0) }
	}

	// A waiter takes the leaver's place, so `holders` only drops when nobody waits.
	func leave() {
		if waiting.isEmpty {
			holders -= 1
		} else {
			waiting.removeFirst().resume()
		}
	}
}
