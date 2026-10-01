//
//  TerminalFDChannel.swift
//  MachmanUI
//
//  The descriptor half of a terminal transport — a pty master or a connected serial socket —
//  shared by PTYProcessStream and SerialTerminalConnection. Everything that touches the
//  descriptor runs on one private serial queue: a read source feeds the transcript and the
//  main queue, a write source drains a bounded outgoing queue, and the descriptor is closed
//  only in the cancel handler of the last source to go. So send() never blocks its caller
//  (P5), and no read, write or ioctl can land on a closed number the process already reused
//  for something else (P6).
//

import Foundation
import MachmanAPI

final class TerminalFDChannel: @unchecked Sendable {
	static let transcriptCap = 8 << 20   // 8 MiB of scrollback for "save to file"
	// Input held for a peer that stopped reading (guest ^S, a stalled ssh or bridge); past
	// it new input is dropped, like the vmhost bridge does towards the guest.
	static let outgoingCap = 8 << 20
	private static let readSize = 16 << 10
	private static let drainBudget = 1 << 20

	private let fd: Int32
	private let label: String
	private let queue: DispatchQueue

	// Confined to `queue`.
	private var readSource: DispatchSourceRead?
	private var writeSource: DispatchSourceWrite?
	private var liveSources = 0
	private var ended = false
	private var outgoing = ByteChunkQueue()
	private var writeFailed = false
	private var warnedDrop = false
	private var readBuffer = [UInt8](repeating: 0, count: TerminalFDChannel.readSize)
	private var onData: ((Data) -> Void)?
	private var onEnd: (() -> Void)?

	// Appended on `queue`, read on the main queue (save to file, session end).
	private let transcriptLock = NSLock()
	private var transcript = ByteChunkQueue()

	// Takes ownership of fd: from here on only this channel closes it.
	init(fd: Int32, label: String) {
		self.fd = fd
		self.label = label
		queue = DispatchQueue(label: "machman.terminal.\(label)", qos: .userInitiated)
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
	}

	// onData runs on the main queue with each chunk, in order; onEnd runs there once, after
	// the last chunk, when the peer hangs up or drainAndEnd() ran. close() ends the channel
	// without onEnd, but a delivery already queued to main still arrives: owners keep their
	// own stopped flag.
	func start(onData: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
		queue.async { [self] in
			guard !ended else { return }
			self.onData = onData
			self.onEnd = onEnd
			let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
			source.setEventHandler { [self] in _ = readOnce() }
			source.setCancelHandler { [self] in sourceGone() }
			readSource = source
			liveSources += 1
			source.resume()
		}
	}

	// Never blocks: what the descriptor takes now is written, the rest waits for the write
	// source, in order.
	func send(_ data: Data) {
		guard !data.isEmpty else { return }
		queue.async { [self] in enqueue(data) }
	}

	// Runs body with the descriptor on the channel's queue, unless the channel has ended.
	func perform(_ body: @escaping (Int32) -> Void) {
		queue.async { [self] in
			guard !ended else { return }
			body(fd)
		}
	}

	// The process behind the descriptor is gone: deliver what it left behind (bounded — a
	// grandchild may still be writing), then end.
	func drainAndEnd() {
		queue.async { [self] in
			var budget = Self.drainBudget
			while budget > 0, !ended, readOnce() { budget -= Self.readSize }
			end(notify: true)
		}
	}

	// The owner is done: no more callbacks; the descriptor closes once the sources are gone.
	func close() {
		queue.async { [self] in end(notify: false) }
	}

	func transcriptData() -> Data {
		transcriptLock.lock()
		defer { transcriptLock.unlock() }
		return transcript.joined()
	}

	// Test seam: the descriptor this channel owns (closed once the channel has ended).
	var descriptor: Int32 { fd }

	// MARK: - On `queue`

	// One read: true when it got bytes (so a drain should keep going).
	private func readOnce() -> Bool {
		guard !ended else { return false }
		let n = read(fd, &readBuffer, readBuffer.count)
		if n > 0 {
			let data = Data(readBuffer[0..<n])
			transcriptLock.lock()
			transcript.append(data)
			if transcript.count > Self.transcriptCap {
				transcript.removeFirst(transcript.count - Self.transcriptCap)
			}
			transcriptLock.unlock()
			if let onData { DispatchQueue.main.async { onData(data) } }
			return true
		}
		if n == 0 || (errno != EAGAIN && errno != EINTR) {
			end(notify: true)
		}
		return false
	}

	private func enqueue(_ data: Data) {
		guard !ended, !writeFailed else { return }
		var pending = data
		if outgoing.isEmpty {
			let sent = data.withUnsafeBytes { writeSome($0) }
			guard !writeFailed else { return }
			pending = data.dropFirst(sent)
		}
		guard !pending.isEmpty else { return }
		let room = max(0, Self.outgoingCap - outgoing.count)
		if pending.count > room {
			if !warnedDrop {
				warnedDrop = true
				MachmanLogger.log(
					.passiveWarning, "terminal \(label): the other end is not reading, "
						+ "dropping input")
			}
			pending = pending.prefix(room)
		}
		outgoing.append(pending)
		armWrite()
	}

	// Writes as much as the descriptor takes now. A hard error (the peer is gone) stops all
	// further input; the read side sees the hang-up and ends the channel. It never touches
	// `outgoing`: flush() calls it from inside outgoing.withHead.
	private func writeSome(_ bytes: UnsafeRawBufferPointer) -> Int {
		guard let base = bytes.baseAddress else { return 0 }
		var off = 0
		while off < bytes.count {
			let n = write(fd, base + off, bytes.count - off)
			if n > 0 { off += n; continue }
			if n < 0 && errno == EINTR { continue }
			if n < 0 && errno != EAGAIN { writeFailed = true }
			break
		}
		return off
	}

	private func armWrite() {
		guard writeSource == nil, !ended, !outgoing.isEmpty else { return }
		let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
		source.setEventHandler { [self] in flush() }
		source.setCancelHandler { [self] in sourceGone() }
		writeSource = source
		liveSources += 1
		source.resume()
	}

	private func flush() {
		while !ended, !writeFailed, let sent = outgoing.withHead({ writeSome($0) }), sent > 0 {
			outgoing.removeFirst(sent)
		}
		if writeFailed { outgoing.removeAll() }
		if outgoing.isEmpty, let source = writeSource {
			writeSource = nil
			warnedDrop = false
			source.cancel()
		}
	}

	private func end(notify: Bool) {
		guard !ended else { return }
		ended = true
		outgoing.removeAll()
		readSource?.cancel()
		readSource = nil
		writeSource?.cancel()
		writeSource = nil
		if liveSources == 0 { Darwin.close(fd) }
		if notify, let onEnd { DispatchQueue.main.async { onEnd() } }
		onData = nil
		onEnd = nil
	}

	// A source's cancel handler: the last one out after the end closes the descriptor.
	private func sourceGone() {
		liveSources -= 1
		if ended && liveSources == 0 { Darwin.close(fd) }
	}
}
