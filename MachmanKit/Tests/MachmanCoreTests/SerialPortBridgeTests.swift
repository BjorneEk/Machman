import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

// The serial data-plane bridge over bare pipes (no VZ): guest output tees to the log and
// broadcasts to socket clients, a late client replays recent context, client input reaches the
// guest, and a dead client can't stall the shared drain.
// .serialized: these tests assert real socket/pipe timing with fixed sleeps — run in
// parallel under host load they starve each other (deadClientDoesNotStopTheDrain flakes).
@Suite(.serialized)
struct SerialPortBridgeTests {

	private func tempPath(_ tag: String, _ ext: String) -> String {
		TestEnvironment.scratch + "mm-\(tag)-\(getpid())-\(UInt32.random(in: 0..<99999)).\(ext)"
	}

	private func makeBridge(
		_ tag: String, log: SerialLogConfig = SerialLogConfig(mode: .disabled)
	) -> (bridge: SerialPortBridge, guestOut: FileHandle, guestIn: FileHandle, logURL: URL) {
		let toGuest = Pipe()      // bridge writes -> guestIn reads
		let fromGuest = Pipe()    // guestOut writes -> bridge reads
		let socketPath = tempPath(tag, "sock")
		let logURL = URL(fileURLWithPath: tempPath(tag, "log"))
		let bridge = SerialPortBridge(
			kind: .console, index: 0, socketPath: socketPath, logURL: logURL,
			logConfig: log, toGuest: toGuest.fileHandleForWriting,
			fromGuest: fromGuest.fileHandleForReading)
		return (bridge, fromGuest.fileHandleForWriting, toGuest.fileHandleForReading, logURL)
	}

	private func connect(_ path: String) -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		_ = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		return fd
	}

	private func recv(_ fd: Int32, until marker: String, timeout: Double = 3) -> String {
		var acc = Data()
		var tv = timeval(tv_sec: 0, tv_usec: 100_000)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			var buf = [UInt8](repeating: 0, count: 4096)
			let n = read(fd, &buf, buf.count)
			if n > 0 { acc.append(contentsOf: buf[0..<n]) }
			if String(decoding: acc, as: UTF8.self).contains(marker) { break }
		}
		return String(decoding: acc, as: UTF8.self)
	}

	private func readPipe(_ handle: FileHandle, until marker: String, timeout: Double = 3) -> String {
		let fd = handle.fileDescriptor
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		var acc = Data()
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			var buf = [UInt8](repeating: 0, count: 4096)
			let n = read(fd, &buf, buf.count)
			if n > 0 { acc.append(contentsOf: buf[0..<n]) }
			else { Thread.sleep(forTimeInterval: 0.05) }
			if String(decoding: acc, as: UTF8.self).contains(marker) { break }
		}
		return String(decoding: acc, as: UTF8.self)
	}

	// Polls the log file until it holds `marker` (the drain and the tee run on the bridge's own
	// queue, so a fixed sleep races them on a loaded machine).
	private func logText(_ url: URL, containing marker: String, timeout: Double = 3) -> String {
		let deadline = Date().addingTimeInterval(timeout)
		var text = ""
		while Date() < deadline {
			text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
			if text.contains(marker) { break }
			Thread.sleep(forTimeInterval: 0.05)
		}
		return text
	}

	@Test func teesToLogAndBroadcastsToClient() throws {
		let env = makeBridge("tee", log: SerialLogConfig(mode: .resetOnBoot))
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)   // let accept register the client

		env.guestOut.write(Data("HELLO_42\n".utf8))
		#expect(recv(client, until: "HELLO_42").contains("HELLO_42"))
		Thread.sleep(forTimeInterval: 0.2)
		let logged = (try? String(contentsOf: env.logURL, encoding: .utf8)) ?? ""
		#expect(logged.contains("HELLO_42"))
	}

	@Test func lateClientReplaysRecentOutput() throws {
		let env = makeBridge("replay")
		env.bridge.start()
		defer { env.bridge.stop() }
		env.guestOut.write(Data("EARLY_OUTPUT\n".utf8))   // before any client attaches
		Thread.sleep(forTimeInterval: 0.3)

		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		#expect(recv(client, until: "EARLY_OUTPUT").contains("EARLY_OUTPUT"))
	}

	@Test func clientInputReachesGuest() throws {
		let env = makeBridge("input")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)

		let typed = "TYPED_INPUT\n"
		_ = typed.utf8CString.withUnsafeBytes { write(client, $0.baseAddress, typed.utf8.count) }
		#expect(readPipe(env.guestIn, until: "TYPED_INPUT").contains("TYPED_INPUT"))
	}

	@Test func deadClientDoesNotStopTheDrain() throws {
		let env = makeBridge("dead")
		env.bridge.start()
		defer { env.bridge.stop() }
		let dead = connect(env.bridge.socketPath)
		let live = connect(env.bridge.socketPath)
		defer { close(live) }
		Thread.sleep(forTimeInterval: 0.2)
		close(dead)   // vanish; a broadcast write to it would raise SIGPIPE (ignored)

		// A burst so the drain writes to the dead fd before noticing EOF — but SMALL enough
		// to fit the live socket's send+receive buffers (~16 KB on macOS AF_UNIX): the
		// broadcast is deliberately best-effort, so a burst bigger than the buffers gets its
		// tail (the marker!) dropped whenever the drain outruns this test's reader. That made
		// the old 25 KB burst fail on an idle machine and pass on a loaded one.
		for _ in 0..<8 { env.guestOut.write(Data(String(repeating: "x", count: 512).utf8)) }
		env.guestOut.write(Data("STILL_ALIVE\n".utf8))
		#expect(recv(live, until: "STILL_ALIVE").contains("STILL_ALIVE"))
	}

	@Test func disabledLoggingWritesNoFile() throws {
		let env = makeBridge("nolog", log: SerialLogConfig(mode: .disabled))
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		env.guestOut.write(Data("SECRET\n".utf8))
		#expect(recv(client, until: "SECRET").contains("SECRET"))
		Thread.sleep(forTimeInterval: 0.2)
		#expect(!FileManager.default.fileExists(atPath: env.logURL.path))
		#expect(env.bridge.currentLogPath() == nil)
	}

	@Test func retuneEnablesLogging() throws {
		let env = makeBridge("retune", log: SerialLogConfig(mode: .disabled))
		env.bridge.start()
		defer { env.bridge.stop() }
		#expect(env.bridge.currentLogPath() == nil)
		env.bridge.retune(SerialLogConfig(mode: .resetOnBoot))
		Thread.sleep(forTimeInterval: 0.2)
		env.guestOut.write(Data("AFTER_RETUNE\n".utf8))
		Thread.sleep(forTimeInterval: 0.3)
		let logged = (try? String(contentsOf: env.logURL, encoding: .utf8)) ?? ""
		#expect(logged.contains("AFTER_RETUNE"))
		#expect(env.bridge.currentLogPath() == env.logURL.path)
	}

	// E23: a cap at or past 2^63 (a script's "no cap") once overflowed `cap * 2` and trapped the
	// vmhost on the first byte; the bridge now treats it as no cap.
	@Test func oversizedCapDoesNotTrap() throws {
		for cap in [UInt64.max, UInt64(1) << 63] {
			let env = makeBridge("cap", log: SerialLogConfig(mode: .resetOnBoot, maxBytes: cap))
			env.bridge.start()
			defer { env.bridge.stop() }
			env.guestOut.write(Data("CAPPED_OUTPUT\n".utf8))
			#expect(logText(env.logURL, containing: "CAPPED_OUTPUT").contains("CAPPED_OUTPUT"))
		}
	}

	// E25: a live retune (Max Size changed, the same mode re-picked) reopens and APPENDS — only
	// the run's first open resets a reset-on-boot log.
	@Test func retuneKeepsThisBootsLog() throws {
		let env = makeBridge("keep", log: SerialLogConfig(mode: .resetOnBoot))
		env.bridge.start()
		defer { env.bridge.stop() }
		env.guestOut.write(Data("BEFORE_RETUNE\n".utf8))
		#expect(logText(env.logURL, containing: "BEFORE_RETUNE").contains("BEFORE_RETUNE"))
		env.bridge.retune(SerialLogConfig(mode: .resetOnBoot, maxBytes: 1 << 20))
		env.guestOut.write(Data("AFTER_RETUNE\n".utf8))
		let logged = logText(env.logURL, containing: "AFTER_RETUNE")
		#expect(logged.contains("BEFORE_RETUNE"))
		#expect(logged.contains("AFTER_RETUNE"))
	}

	// E25's other half: starting still drops the previous boot's output, and so does a
	// reset-on-boot log first opened mid-run (logging was off at start).
	@Test func firstOpenOfARunResetsThePreviousBoot() throws {
		for startMode in [SerialLogMode.resetOnBoot, .disabled] {
			let env = makeBridge("reset", log: SerialLogConfig(mode: startMode))
			try Data("OLD_BOOT\n".utf8).write(to: env.logURL)
			env.bridge.start()
			defer { env.bridge.stop() }
			if startMode == .disabled {
				env.bridge.retune(SerialLogConfig(mode: .resetOnBoot))
			}
			env.guestOut.write(Data("NEW_BOOT\n".utf8))
			let logged = logText(env.logURL, containing: "NEW_BOOT")
			#expect(logged.contains("NEW_BOOT"))
			#expect(!logged.contains("OLD_BOOT"))
		}
	}

	// E18: typing at a guest that reads nothing fills the 16 KB pipe; the bridge must buffer and
	// drop instead of blocking its queue — which also runs the always-on drain.
	@Test func unreadGuestInputDoesNotStallTheDrain() throws {
		let env = makeBridge("stall")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		_ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
		let chunk = [UInt8](repeating: 0x61, count: 4096)
		var typed = 0
		let deadline = Date().addingTimeInterval(3)
		while typed < 256 * 1024, Date() < deadline {
			let n = chunk.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
			if n > 0 { typed += n } else { Thread.sleep(forTimeInterval: 0.01) }
		}
		#expect(typed == 256 * 1024)   // the bridge kept reading its client
		env.guestOut.write(Data("STILL_DRAINING\n".utf8))
		#expect(recv(client, until: "STILL_DRAINING").contains("STILL_DRAINING"))
	}

	// E18's teardown race: the guest end of the input pipe closes (VZ tearing down) while a
	// client still types. EPIPE must drop the input, not raise an ObjC exception.
	@Test func inputAfterTheGuestEndClosedIsDropped() throws {
		let env = makeBridge("epipe")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		try env.guestIn.close()
		let typed = "AFTER_GUEST_GONE\n"
		_ = typed.utf8CString.withUnsafeBytes { write(client, $0.baseAddress, typed.utf8.count) }
		Thread.sleep(forTimeInterval: 0.2)
		env.guestOut.write(Data("STILL_ALIVE\n".utf8))
		#expect(recv(client, until: "STILL_ALIVE").contains("STILL_ALIVE"))
	}

	// E18: what the pipe can't take at once is buffered, not lost — below the cap a slow guest
	// still receives every byte, in order.
	@Test func bufferedInputReachesASlowGuestInOrder() throws {
		let env = makeBridge("order")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		_ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
		let sent = Data((0..<(60 * 1024)).map { UInt8(truncatingIfNeeded: $0 % 251) })
		var off = 0
		let deadline = Date().addingTimeInterval(3)
		while off < sent.count, Date() < deadline {
			let n = sent.withUnsafeBytes {
				write(client, $0.baseAddress! + off, min(4096, sent.count - off))
			}
			if n > 0 { off += n } else { Thread.sleep(forTimeInterval: 0.01) }
		}
		#expect(off == sent.count)
		Thread.sleep(forTimeInterval: 0.3)   // the guest starts reading only now
		let fd = env.guestIn.fileDescriptor
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		var got = Data()
		let readDeadline = Date().addingTimeInterval(3)
		while got.count < sent.count, Date() < readDeadline {
			var buf = [UInt8](repeating: 0, count: 16 * 1024)
			let n = read(fd, &buf, buf.count)
			if n > 0 {
				got.append(contentsOf: buf[0..<n])
			} else {
				Thread.sleep(forTimeInterval: 0.02)
			}
		}
		#expect(got == sent)
	}
}
