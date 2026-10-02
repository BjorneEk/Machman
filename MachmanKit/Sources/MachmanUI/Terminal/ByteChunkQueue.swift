//
//  ByteChunkQueue.swift
//  MachmanUI
//
//  A FIFO of byte chunks for the terminal transports: appends at the tail and consumes from
//  the head without moving what stays. Three users — the bounded transcript (trim the head to a
//  cap), the outgoing queue (consume what write() took) and the output waiting for delivery
//  (taken a chunk at a time). The head is tracked by index and
//  offset, so a dropped chunk is really freed: cutting the head off one big Data only slices
//  it, and the slice keeps the whole buffer alive (a capped Data transcript retained every
//  byte the session ever printed).
//

import Foundation

struct ByteChunkQueue {
	private var chunks: [Data] = []
	private var head = 0          // the first live chunk
	private var headOffset = 0    // bytes of chunks[head] already consumed
	private(set) var count = 0

	var isEmpty: Bool { count == 0 }

	mutating func append(_ data: Data) {
		guard !data.isEmpty else { return }
		chunks.append(data)
		count += data.count
	}

	// Drops up to n bytes from the head.
	mutating func removeFirst(_ n: Int) {
		var left = min(max(n, 0), count)
		count -= left
		while left > 0 {
			let available = chunks[head].count - headOffset
			if left < available {
				headOffset += left
				break
			}
			left -= available
			chunks[head] = Data()
			head += 1
			headOffset = 0
		}
		if count == 0 {
			removeAll()
		} else if head >= 64, head * 2 >= chunks.count {
			chunks.removeFirst(head)
			head = 0
		}
	}

	mutating func removeAll() {
		chunks.removeAll()
		head = 0
		headOffset = 0
		count = 0
	}

	// Takes the head chunk's unconsumed bytes off the queue, as they were appended.
	mutating func popFirst() -> Data? {
		guard count > 0 else { return nil }
		var chunk = chunks[head]
		if headOffset > 0 {
			chunk = chunk.subdata(in: (chunk.startIndex + headOffset)..<chunk.endIndex)
		}
		removeFirst(chunk.count)
		return chunk
	}

	// The head chunk's unconsumed bytes — what the next write() should try.
	func withHead<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R? {
		guard count > 0 else { return nil }
		return chunks[head].withUnsafeBytes { raw in
			body(UnsafeRawBufferPointer(rebasing: raw[headOffset...]))
		}
	}

	// Everything queued, as one fresh contiguous Data.
	func joined() -> Data {
		var out = Data(capacity: count)
		guard count > 0 else { return out }
		chunks[head].withUnsafeBytes { out.append(contentsOf: $0[headOffset...]) }
		for chunk in chunks[(head + 1)...] { out.append(chunk) }
		return out
	}
}
