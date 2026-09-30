//
//  SerialTerminalConnection.swift
//  MachmanDesktopUI
//
//  A raw client for a serial port's data-plane unix socket. The desktop opens the vmhost's
//  per-port socket directly (its path comes from SerialPortInfo.socketPath) — the daemon never
//  proxies the byte stream. Reads on a background thread and delivers to the main actor; also
//  keeps a bounded transcript so the terminal view can be saved to a file.
//

import Foundation
import MachmanUI
import MachmanDesktopCore

final class SerialTerminalConnection: TerminalByteStream {
	private let path: String
	private var fd: Int32 = -1
	private var readSource: DispatchSourceRead?
	private let transcriptLock = NSLock()
	private var transcript = Data()
	private static let transcriptCap = 8 << 20   // 8 MiB of scrollback for "save to file"

	// Called on the main queue with each chunk of guest output.
	var onData: ((Data) -> Void)?
	// Called on the main queue if the socket closes (VM stopped, vmhost gone).
	var onClose: (() -> Void)?

	init(path: String) {
		self.path = path
	}

	func connect() -> Bool {
		let s = socket(AF_UNIX, SOCK_STREAM, 0)
		guard s >= 0 else { return false }
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		let ok = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard ok == 0 else { close(s); return false }
		fd = s
		let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: .global())
		source.setEventHandler { [weak self] in
			guard let self = self else { return }
			var buf = [UInt8](repeating: 0, count: 8192)
			let n = read(self.fd, &buf, buf.count)
			if n > 0 {
				let data = Data(buf[0..<n])
				self.appendTranscript(data)
				DispatchQueue.main.async { self.onData?(data) }
			} else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
				self.stop()
				DispatchQueue.main.async { self.onClose?() }
			}
		}
		readSource = source
		source.resume()
		return true
	}

	func send(_ data: Data) {
		guard fd >= 0 else { return }
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var off = 0
			while off < data.count {
				let n = write(fd, base + off, data.count - off)
				if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
			}
		}
	}

	func stop() {
		readSource?.cancel()
		readSource = nil
		if fd >= 0 { close(fd); fd = -1 }
	}

	func transcriptData() -> Data {
		transcriptLock.lock(); defer { transcriptLock.unlock() }
		return transcript
	}

	private func appendTranscript(_ data: Data) {
		transcriptLock.lock()
		transcript.append(data)
		if transcript.count > Self.transcriptCap {
			transcript.removeFirst(transcript.count - Self.transcriptCap)
		}
		transcriptLock.unlock()
	}

	deinit { stop() }
}
