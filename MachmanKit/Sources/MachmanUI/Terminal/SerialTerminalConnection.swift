//
//  SerialTerminalConnection.swift
//  MachmanUI
//
//  A raw client for a serial port's data-plane unix socket. The desktop opens the vmhost's
//  per-port socket directly (its path comes from SerialPortInfo.socketPath) — the daemon never
//  proxies the byte stream. The descriptor side (reads off the main thread, non-blocking
//  sends, the bounded transcript for "save to file") is the shared TerminalFDChannel.
//

import Foundation

public final class SerialTerminalConnection: TerminalByteStream {
	private let path: String
	private var channel: TerminalFDChannel?
	private var stopped = false

	// Called on the main queue with each chunk of guest output.
	public var onData: ((Data) -> Void)?
	// Called on the main queue if the socket closes (VM stopped, vmhost gone).
	public var onClose: (() -> Void)?

	public init(path: String) {
		self.path = path
	}

	// One connection per stream: a second connect() is refused.
	public func connect() -> Bool {
		guard channel == nil, !stopped, let s = Self.connectedSocket(path: path) else {
			return false
		}
		let channel = TerminalFDChannel(fd: s, label: "serial")
		self.channel = channel
		channel.start(
			onData: { [weak self] data in
				guard let self, !self.stopped else { return }
				self.onData?(data)
			},
			onEnd: { [weak self] in
				guard let self, !self.stopped else { return }
				self.onClose?()
			})
		return true
	}

	// A socket connected to the bridge at `path`, or nil.
	static func connectedSocket(path: String) -> Int32? {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		let s = newSocket()
		guard s >= 0 else { return nil }
		let ok = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard ok == 0 else { close(s); return nil }
		return s
	}

	// A socket set up before it connects: a keystroke racing the vmhost's exit fails with EPIPE
	// instead of killing the app. Before the connect, never after: Darwin refuses SO_NOSIGPIPE
	// (EINVAL) on a socket whose peer already hung up, so a tab connecting or rejoining while
	// its bridge went away died by SIGPIPE on its first keystroke (E60). -1 with no socket.
	static func newSocket() -> Int32 {
		let s = socket(AF_UNIX, SOCK_STREAM, 0)
		guard s >= 0 else { return s }
		var on: Int32 = 1
		_ = setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		return s
	}

	public func send(_ data: Data) {
		channel?.send(data)
	}

	public func stop() {
		stopped = true
		channel?.close()
	}

	public func transcriptData() -> Data {
		channel?.transcriptData() ?? Data()
	}

	// Test seam: the socket while connected.
	var descriptor: Int32? { channel?.descriptor }

	deinit { channel?.close() }
}
