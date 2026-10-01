//
//  TerminalByteStream.swift
//  MachmanUI
//
//  The byte-stream seam a terminal controller talks to: the serial unix-socket client
//  (desktop) or a PTY-backed process (PTYProcessStream, the ephemeral SSH tabs) — same
//  members, same main-queue delivery contract, so the controller neither knows nor cares.
//

import Foundation

public protocol TerminalByteStream: AnyObject {
	// Called on the main queue with each chunk of remote output.
	var onData: ((Data) -> Void)? { get set }
	// Called on the main queue when the stream ends (socket closed, process exited).
	var onClose: (() -> Void)? { get set }
	func connect() -> Bool
	// Never blocks: a peer that stopped reading queues input (bounded), not the caller.
	func send(_ data: Data)
	func stop()
	func transcriptData() -> Data
	// Window-size changes: PTY streams forward TIOCSWINSZ (a size set before connect() is
	// the session's first size); a serial console has no size channel (the default no-op).
	func setWindowSize(cols: Int, rows: Int)
}

public extension TerminalByteStream {
	func setWindowSize(cols: Int, rows: Int) {}
}
