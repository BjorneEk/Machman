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
		TestEnvironment.socketPath("mm-\(tag)", suffix: ".\(ext)")
	}

	private func makeBridge(
		_ tag: String, log: SerialLogConfig = SerialLogConfig(mode: .disabled),
		clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
	) -> (bridge: SerialPortBridge, guestOut: FileHandle, guestIn: FileHandle, logURL: URL) {
		let toGuest = Pipe()      // bridge writes -> guestIn reads
		let fromGuest = Pipe()    // guestOut writes -> bridge reads
		let socketPath = tempPath(tag, "sock")
		let logURL = URL(fileURLWithPath: tempPath(tag, "log"))
		let bridge = SerialPortBridge(
			kind: .console, index: 0, socketPath: socketPath, logURL: logURL,
			logConfig: log, toGuest: toGuest.fileHandleForWriting,
			fromGuest: fromGuest.fileHandleForReading, clock: clock)
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

		// A burst so the drain writes to the dead fd before noticing EOF. (It once had to fit
		// the live socket's ~16 KB of buffers: past them the broadcast dropped the tail, the
		// marker with it, whenever the drain outran this test's reader — E58.)
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

	// The bridge's counts once `done` holds them (they move on its own queue).
	private func counts(
		_ bridge: SerialPortBridge, timeout: Double = 3,
		until done: ((port: SerialPortBridge.Counters, clients: [SerialPortBridge.ClientCounts]))
			-> Bool
	) -> (port: SerialPortBridge.Counters, clients: [SerialPortBridge.ClientCounts]) {
		let deadline = Date().addingTimeInterval(timeout)
		var now = bridge.countsForTesting
		while !done(now), Date() < deadline {
			Thread.sleep(forTimeInterval: 0.02)
			now = bridge.countsForTesting
		}
		return now
	}

	// E58: a console that seemed to stop taking input — the counts tell input lost here from
	// a guest that stopped reading (input waiting) and from output a client never got.
	@Test("E58: the bridge counts every byte in and out, and typed is taken, waiting or dropped")
	func countsEveryByte() throws {
		let env = makeBridge("counts")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)

		let typed = "TYPED\n"
		_ = typed.utf8CString.withUnsafeBytes { write(client, $0.baseAddress, typed.utf8.count) }
		#expect(readPipe(env.guestIn, until: "TYPED").contains("TYPED"))
		env.guestOut.write(Data("ECHO_42\n".utf8))
		#expect(recv(client, until: "ECHO_42").contains("ECHO_42"))
		let first = counts(env.bridge) { $0.port.output == 8 && $0.clients.first?.sent == 8 }
		#expect(first.port == SerialPortBridge.Counters(typed: 6, taken: 6, output: 8))
		#expect(first.clients == [SerialPortBridge.ClientCounts(sent: 8, lost: 0)])

		// A guest that reads nothing more: the pipe and the 64 KiB buffer fill, the rest is
		// dropped with one warning, and every typed byte is still accounted for.
		_ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
		let chunk = [UInt8](repeating: 0x61, count: 4096)
		var sent = 0
		let deadline = Date().addingTimeInterval(3)
		while sent < 256 * 1024, Date() < deadline {
			let n = chunk.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
			if n > 0 { sent += n } else { Thread.sleep(forTimeInterval: 0.01) }
		}
		#expect(sent == 256 * 1024)
		let full = counts(env.bridge) { $0.port.typed == UInt64(6 + sent) }
		#expect(full.port.typed == UInt64(6 + sent))
		#expect(full.port.taken + full.port.waiting + full.port.dropped == full.port.typed)
		#expect(full.port.waiting == 64 * 1024)
		#expect(full.port.dropped > 0)
		#expect(full.port.dropWarnings == 1)
	}

	@Test("E58: the counts read as one log line, with a leaving client's share")
	func countsReadAsOneLine() {
		let counts = SerialPortBridge.Counters(
			typed: 12, taken: 10, waiting: 2, dropped: 0, output: 4096)
		#expect(counts.line(port: "console2")
			== "serial console2 counts: typed 12, taken 10, waiting 2, dropped 0, output 4096")
		#expect(counts.line(port: "console2", client: .init(sent: 4000, lost: 96))
			== "serial console2 counts: typed 12, taken 10, waiting 2, dropped 0, output 4096; "
				+ "client got 4000, lost 96")
	}

	// E58: a client that stopped reading for a moment (a busy terminal, a loaded test) lost
	// what its socket could not take at once — all but 8 KiB of a burst, the echo a console
	// session waited for among it. Its output now waits for it (C29: up to 1 MiB).
	@Test("E58: a client that stops reading for a moment still gets every byte of a 64 KiB burst")
	func aPausedClientGetsTheWholeBurst() throws {
		let env = makeBridge("paused")
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)

		let burst = String(repeating: "x", count: 64 * 1024) + "END_OF_BURST\n"
		env.guestOut.write(Data(burst.utf8))   // the client reads nothing meanwhile
		let total = UInt64(burst.utf8.count)
		#expect(counts(env.bridge) { $0.port.output == total }.port.output == total)
		let got = recv(client, until: "END_OF_BURST", timeout: 5)
		#expect(got.hasSuffix("END_OF_BURST\n"))
		#expect(got.utf8.count == burst.utf8.count)
		#expect(counts(env.bridge) { $0.clients.first?.sent == total }.clients
			== [SerialPortBridge.ClientCounts(sent: total, lost: 0)])
	}

	// Reads a client's socket until the bridge closes it: what it got, and whether it ended.
	private func recvToEnd(_ fd: Int32, timeout: Double = 5) -> (data: Data, ended: Bool) {
		var tv = timeval(tv_sec: 0, tv_usec: 100_000)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		var got = Data()
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			var buf = [UInt8](repeating: 0, count: 64 * 1024)
			let n = read(fd, &buf, buf.count)
			if n > 0 { got.append(contentsOf: buf[0..<n]) } else if n == 0 { return (got, true) }
		}
		return (got, false)
	}

	// …and one that never reads is stuck once it is 1 MiB behind: C29 closes it rather than
	// hand it output with a hole in it, the drain goes on for the others, and a terminal that
	// comes back gets the replay.
	@Test("C29: a client 1 MiB behind is closed, and its reconnect gets the replay")
	func aStuckClientIsClosedAndComesBackToTheReplay() throws {
		let env = makeBridge("stuck")
		env.bridge.start()
		defer { env.bridge.stop() }
		let stuck = connect(env.bridge.socketPath)
		defer { close(stuck) }
		Thread.sleep(forTimeInterval: 0.2)

		let chunk = Data(repeating: 0x79, count: 64 * 1024)
		for _ in 0..<24 { env.guestOut.write(chunk) }   // 1.5 MiB the client never reads
		env.guestOut.write(Data("STILL_FLOWING\n".utf8))
		let output = UInt64(24 * 64 * 1024 + 14)
		#expect(counts(env.bridge) { $0.port.output == output }.clients.isEmpty)
		let (got, ended) = recvToEnd(stuck)
		#expect(ended, "the stuck client was not closed")
		#expect(got.count < 1024 * 1024 + 64 * 1024)   // its socket's share, not the rest

		let back = connect(env.bridge.socketPath)
		defer { close(back) }
		let replay = recv(back, until: "STILL_FLOWING")
		#expect(replay.hasSuffix("STILL_FLOWING\n"))
		#expect(replay.utf8.count == 256 * 1024)   // the whole ring
	}

	// The socket goes before the clients: a terminal whose connection ends finds no bridge
	// to come back to, and so never takes a stop for being closed as stuck.
	@Test("C29: a stopped bridge's socket is gone before its clients see the end")
	func aStoppedBridgeUnlinksBeforeClosingClients() throws {
		let env = makeBridge("stopping")
		env.bridge.start()
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		env.bridge.stop()
		#expect(recvToEnd(client).ended)
		#expect(!FileManager.default.fileExists(atPath: env.bridge.socketPath))
	}

	// Types `count` bytes from a non-blocking client that the guest doesn't read: the bridge
	// takes all of it (buffering or dropping), so the writes never stall.
	private func paste(_ client: Int32, _ count: Int) {
		let chunk = [UInt8](repeating: 0x70, count: 4096)
		var sent = 0
		let deadline = Date().addingTimeInterval(3)
		while sent < count, Date() < deadline {
			let n = chunk.withUnsafeBytes {
				write(client, $0.baseAddress, min($0.count, count - sent))
			}
			if n > 0 { sent += n } else { Thread.sleep(forTimeInterval: 0.01) }
		}
	}

	// Reads the guest end until the bridge has nothing waiting and the pipe is empty.
	private func drainGuest(_ bridge: SerialPortBridge, _ guestIn: FileHandle) {
		let fd = guestIn.fileDescriptor
		_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
		var buf = [UInt8](repeating: 0, count: 64 * 1024)
		let deadline = Date().addingTimeInterval(5)
		while Date() < deadline {
			if read(fd, &buf, buf.count) > 0 { continue }
			if bridge.countsForTesting.port.waiting == 0, read(fd, &buf, buf.count) <= 0 {
				return
			}
			Thread.sleep(forTimeInterval: 0.005)
		}
	}

	// E59: under four lab shards the guest drained the bridge's buffer once mid-paste, and the
	// "guest not reading input" warning came twice. C25: one warning per paste burst — it
	// re-arms only after nothing has waited for the guest for a second.
	@Test("E59: an unread paste warns once per burst, and again after the guest kept up a second")
	func unreadPasteWarnsOncePerBurst() throws {
		let time = ManualClock()
		let env = makeBridge("burst", clock: { time.now })
		env.bridge.start()
		defer { env.bridge.stop() }
		let client = connect(env.bridge.socketPath)
		defer { close(client) }
		Thread.sleep(forTimeInterval: 0.2)
		_ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
		let burst = 256 * 1024

		paste(client, burst)
		#expect(counts(env.bridge) { $0.port.typed == UInt64(burst) }.port.dropWarnings == 1)
		drainGuest(env.bridge, env.guestIn)   // the guest drains it at once…
		paste(client, burst)                  // …and the paste goes on: the same burst
		#expect(counts(env.bridge) { $0.port.typed == UInt64(2 * burst) }.port.dropWarnings
			== 1)
		drainGuest(env.bridge, env.guestIn)
		time.advance(seconds: 1.5)            // caught up for a second: a new paste warns
		paste(client, burst)
		#expect(counts(env.bridge) { $0.port.typed == UInt64(3 * burst) }.port.dropWarnings
			== 2)
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

// A monotonic clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
	private let lock = NSLock()
	private var nanoseconds: UInt64 = 1_000_000_000

	var now: UInt64 { lock.withLock { nanoseconds } }

	func advance(seconds: Double) {
		lock.withLock { nanoseconds += UInt64(seconds * 1_000_000_000) }
	}
}
