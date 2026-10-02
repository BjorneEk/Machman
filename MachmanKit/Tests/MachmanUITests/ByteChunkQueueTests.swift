//
//  ByteChunkQueueTests.swift
//  MachmanUITests
//
//  The chunk FIFO behind the terminal transcripts and send queues: it trims and consumes
//  across chunk boundaries and hands out compact copies.
//

import Testing
import Foundation
@testable import MachmanUI

struct ByteChunkQueueTests {

	@Test func trimsTheHeadAcrossChunkBoundaries() {
		var queue = ByteChunkQueue()
		for i in 0..<10 { queue.append(Data(repeating: UInt8(i), count: 100)) }
		queue.removeFirst(250)
		#expect(queue.count == 750)
		let all = queue.joined()
		#expect(all.count == 750)
		#expect(all.startIndex == 0)
		#expect(all.first == 2 && all.last == 9)
		#expect(queue.withHead { $0.count } == 50)
	}

	// The delivery queue hands chunks out whole, in order, a part-consumed head as its rest.
	@Test func popsChunksInOrder() {
		var queue = ByteChunkQueue()
		queue.append(Data("abc".utf8))
		queue.append(Data("de".utf8))
		queue.removeFirst(1)
		#expect(queue.popFirst() == Data("bc".utf8))
		#expect(queue.count == 2)
		#expect(queue.popFirst() == Data("de".utf8))
		#expect(queue.popFirst() == nil)
		#expect(queue.isEmpty)
	}

	@Test func emptiesAndRefills() {
		var queue = ByteChunkQueue()
		queue.append(Data("abc".utf8))
		queue.removeFirst(3)
		#expect(queue.isEmpty)
		#expect(queue.withHead { $0.count } == nil)
		queue.append(Data("de".utf8))
		#expect(queue.joined() == Data("de".utf8))
		queue.removeFirst(99)
		#expect(queue.isEmpty)
		#expect(queue.joined().isEmpty)
	}

	@Test func aCappedQueueOfManySmallChunksKeepsItsTail() {
		var queue = ByteChunkQueue()
		for i in 0..<10_000 {
			queue.append(Data([UInt8(truncatingIfNeeded: i)]))
			if queue.count > 100 { queue.removeFirst(queue.count - 100) }
		}
		#expect(queue.count == 100)
		#expect(queue.joined() == Data((9_900..<10_000).map { UInt8(truncatingIfNeeded: $0) }))
	}
}
