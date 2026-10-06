//
//  LabHarnessSupport.swift
//  MachmanLabTests
//
//  Test doubles for the lab's own machinery.
//

import Foundation
import MachmanTestSupport

/// A console socket that greets one client, echoes its lines like a tty and answers the
/// lab console client's marker command.
final class FakeConsoleServer: @unchecked Sendable {
	let path = TestEnvironment.socketPath("labcon")

	private let greeting: String
	private let respond: @Sendable (String) -> (output: String, status: Int32)
	private let lock = NSLock()
	private var listener: Int32 = -1
	private var client: Int32 = -1
	private var closeRequested = false
	private var stopped = false

	init(
		greeting: String, respond: @escaping @Sendable (String) -> (output: String, status: Int32)
	) throws {
		self.greeting = greeting
		self.respond = respond
		unlink(path)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &address.sun_path) { raw in
			for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
		}
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard bound == 0, listen(fd, 4) == 0 else {
			Darwin.close(fd)
			throw LabError.consoleUnavailable("fake console: can't listen on \(path)")
		}
		listener = fd
		Thread.detachNewThread { [self] in serve() }
	}

	private func serve() {
		let accepted = accept(listener, nil, nil)
		guard accepted >= 0 else { return }
		var one: Int32 = 1
		setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
		lock.lock()
		client = accepted
		let closeNow = closeRequested
		lock.unlock()
		if closeNow {
			Darwin.close(accepted)
			return
		}
		write(greeting)
		var buffer = [UInt8](repeating: 0, count: 4096)
		var line = [UInt8]()
		while true {
			let n = Darwin.read(accepted, &buffer, buffer.count)
			if n <= 0 { break }
			for byte in buffer[0..<n] {
				guard byte == 0x0A else {
					line.append(byte)
					continue
				}
				let text = String(decoding: line, as: UTF8.self)
				line = []
				answer(text)
			}
		}
		Darwin.close(accepted)
	}

	private func answer(_ line: String) {
		write(line + "\r\n")
		let pattern = "^(.*?)(?:; |(?<=&) )echo 'LAB''(\\d+)X' \\$\\?$"
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
		else { return }
		let command = (line as NSString).substring(with: match.range(at: 1))
		let marker = (line as NSString).substring(with: match.range(at: 2))
		let result = respond(command)
		if !result.output.isEmpty { write(result.output + "\r\n") }
		write("LAB\(marker)X \(result.status)\r\n# ")
	}

	private func write(_ text: String) {
		lock.lock()
		let fd = client
		lock.unlock()
		guard fd >= 0 else { return }
		let bytes = Array(text.utf8)
		var offset = 0
		while offset < bytes.count {
			let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
			if n <= 0 { return }
			offset += n
		}
	}

	func send(_ text: String) { write(text) }

	/// Closes the client's connection (now, or as soon as it arrives).
	func closeClient() {
		lock.lock()
		closeRequested = true
		let fd = client
		lock.unlock()
		if fd >= 0 { shutdown(fd, SHUT_RDWR) }
	}

	func stop() {
		lock.lock()
		let alreadyStopped = stopped
		stopped = true
		let fd = listener
		lock.unlock()
		if !alreadyStopped {
			shutdown(fd, SHUT_RDWR)
			Darwin.close(fd)
			unlink(path)
		}
		closeClient()
	}
}
