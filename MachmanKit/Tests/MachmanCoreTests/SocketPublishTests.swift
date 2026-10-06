//
//  SocketPublishTests.swift
//  MachmanCoreTests
//
//  E48: a listener bound its socket at the served path and only then listened. A starter
//  probing the path in between had its connect refused, read the fresh socket as dead,
//  unlinked it and bound its own: two listeners "serving" one path, one of them unreachable.
//  A socket's path now appears only once it listens.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct SocketPublishTests {
	@Test("E48: of starters racing for one socket path, exactly one serves it")
	func ofStartersRacingForOnePathExactlyOneServesIt() async throws {
		let dir = TestEnvironment.socketPath("mm-race", suffix: "")
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		// The window is a few system calls wide, yet about one round in six hit it at base.
		let rounds = 500
		let starters = 4
		let doubled = await offPool { () -> Int in
			let queue = DispatchQueue(label: "mm-race-accept")
			var doubled = 0
			for round in 0..<rounds {
				let path = dir + "/r\(round % 50).sock"
				let lock = NSLock()
				var listeners: [UDSListener] = []
				DispatchQueue.concurrentPerform(iterations: starters) { _ in
					guard let listener = try? UDSListener(path: path, queue: queue, onAccept: {
						close($0)
					}) else { return }
					lock.withLock { listeners.append(listener) }
				}
				if listeners.count != 1 { doubled += 1 }
				listeners.forEach { $0.shutdown() }
			}
			return doubled
		}
		#expect(doubled == 0, "\(doubled) of \(rounds) rounds ended with other than one serving")
	}
}
