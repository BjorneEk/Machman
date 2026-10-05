//
//  LabConsole.swift
//  MachmanLabTests
//
//  A client for a VM's console socket. The socket carries raw serial bytes, and the vmhost
//  replays up to 256 KB of earlier output on connect, so a client that connects late still
//  sees the boot. Output is cleaned (CR, colour and cursor codes) before a pattern is matched,
//  and every byte is kept in a transcript file the run's report carries.
//

import Foundation
import MachmanTestSupport

final class LabConsole: @unchecked Sendable {
	let path: String
	let transcriptPath: String

	private let fd: Int32
	private let lock = NSLock()
	private var pending: [UInt8] = []
	private var closed = false
	private var closing = false
	private var text = ""
	private var seq = 0
	private let transcript: FileHandle?

	private static let escapes = try! NSRegularExpression(
		pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-Za-z]")

	private init(path: String, fd: Int32, transcriptPath: String) {
		self.path = path
		self.fd = fd
		self.transcriptPath = transcriptPath
		FileManager.default.createFile(atPath: transcriptPath, contents: nil)
		transcript = FileHandle(forWritingAtPath: transcriptPath)
		Thread.detachNewThread { [self] in readLoop() }
	}

	/// Connects to `path`, retrying every 250 ms until `timeout`.
	static func connect(
		_ path: String, transcript name: String, timeout: Duration = .seconds(30)
	) async throws -> LabConsole {
		guard path.utf8.count <= 103 else {
			throw LabError.consoleUnavailable("console socket path too long: \(path)")
		}
		let dir = Lab.runDir.isEmpty ? TestEnvironment.scratch : Lab.transcriptsDir + "/"
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let transcriptPath = dir + name + ".log"
		let deadline = ContinuousClock.now + timeout
		while true {
			let fd = await offPool { connectOnce(path) }
			if fd >= 0 {
				return LabConsole(path: path, fd: fd, transcriptPath: transcriptPath)
			}
			if ContinuousClock.now >= deadline {
				throw LabError.consoleUnavailable("nothing serves \(path)")
			}
			try await Task.sleep(for: .milliseconds(250))
		}
	}

	private static func connectOnce(_ path: String) -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return -1 }
		var one: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8)
		withUnsafeMutableBytes(of: &address.sun_path) { raw in
			for (index, byte) in bytes.enumerated() { raw[index] = byte }
		}
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if result != 0 {
			Darwin.close(fd)
			return -1
		}
		return fd
	}

	// Only this loop ever closes the descriptor; close() just shuts the socket down.
	private func readLoop() {
		var buffer = [UInt8](repeating: 0, count: 65536)
		while true {
			let n = Darwin.read(fd, &buffer, buffer.count)
			if n < 0 && errno == EINTR { continue }
			if n <= 0 { break }
			let chunk = Array(buffer[0..<n])
			lock.lock()
			pending.append(contentsOf: chunk)
			lock.unlock()
			transcript?.write(Data(chunk.filter { $0 != 0x0D }))
		}
		lock.lock()
		closed = true
		lock.unlock()
		Darwin.close(fd)
		try? transcript?.close()
	}

	func send(_ line: String) throws { try sendRaw(Array((line + "\n").utf8)) }

	func sendRaw(_ bytes: [UInt8]) throws {
		lock.lock()
		let unusable = closed || closing
		lock.unlock()
		if unusable { throw LabError.consoleClosed(tail: tail) }
		var offset = 0
		while offset < bytes.count {
			let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
			if n < 0 && errno == EINTR { continue }
			if n <= 0 { throw LabError.consoleClosed(tail: tail) }
			offset += n
		}
	}

	func close() {
		lock.lock()
		closing = true
		lock.unlock()
		shutdown(fd, SHUT_RDWR)
	}

	/// The last 2,000 characters of the output nobody matched yet.
	var tail: String {
		lock.lock()
		defer { lock.unlock() }
		return String((text + clean(String(decoding: pending, as: UTF8.self))).suffix(2000))
	}

	private func clean(_ raw: String) -> String {
		var result = raw.replacingOccurrences(of: "\r", with: "")
		let range = NSRange(result.startIndex..., in: result)
		result = Self.escapes.stringByReplacingMatches(in: result, range: range, withTemplate: "")
		return result
	}

	// Moves what arrived into `text`; returns it and whether the console has closed.
	private func drain() -> (text: String, closed: Bool) {
		lock.withLock {
			text += clean(String(decoding: pending, as: UTF8.self))
			pending = []
			if text.count > 4_000_000 { text = String(text.suffix(1_000_000)) }
			return (text, closed)
		}
	}

	private func consume(rest: String) { lock.withLock { text = rest } }

	/// Waits for `pattern` (anchorsMatchLines) and returns group 0 and the captures, with ""
	/// for a group that took no part. Output before the match is consumed with it.
	@discardableResult
	func expect(_ pattern: String, timeout: Duration = .seconds(30)) async throws -> [String] {
		let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
		let deadline = ContinuousClock.now + timeout
		while true {
			let (snapshot, isClosed) = drain()
			let whole = NSRange(snapshot.startIndex..., in: snapshot)
			if let match = regex.firstMatch(in: snapshot, range: whole) {
				var groups: [String] = []
				for index in 0..<match.numberOfRanges {
					let range = match.range(at: index)
					groups.append(range.location == NSNotFound
						? "" : (snapshot as NSString).substring(with: range))
				}
				consume(rest: (snapshot as NSString).substring(from: match.range.upperBound))
				return groups
			}
			if isClosed { throw LabError.consoleClosed(tail: tail) }
			if ContinuousClock.now >= deadline {
				throw LabError.expectTimeout(pattern: pattern, tail: tail)
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	/// Runs one shell command (no newlines in it) and returns its status and output. The
	/// marker's split quoting keeps the echoed command line from matching it.
	func run(
		_ command: String, timeout: Duration = .seconds(60)
	) async throws -> (status: Int32, output: String) {
		seq += 1
		let n = seq
		try send("\(command); echo 'LAB''\(n)X' $?")
		let groups = try await expect("\\A(?s:(.*?))LAB\(n)X (\\d+)\\n", timeout: timeout)
		var lines = groups[1].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		if let echoed = lines.lastIndex(where: { $0.contains("\(n)X' $?") }) {
			lines.removeSubrange(0...echoed)
		}
		let output = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
		return (Int32(groups[2]) ?? -1, output)
	}

	/// Logs in on a getty and proves the shell answers.
	func login(
		user: String = "root", password: String? = nil, timeout: Duration = .seconds(180)
	) async throws {
		try send("")
		try await expect("login: *$", timeout: timeout)
		try send(user)
		if let password {
			try await expect("[Pp]assword: *$", timeout: .seconds(30))
			try send(password)
		}
		try await expect("[#$] *$", timeout: .seconds(60))
		let probe = try await run("true")
		guard probe.status == 0 else {
			throw LabError.commandFailed(command: "true", status: probe.status, output: probe.output)
		}
	}
}
