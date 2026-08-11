import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

// The serial data-plane bridge over bare pipes (no VZ): guest output tees to the log and
// broadcasts to socket clients, a late client replays recent context, client input reaches the
// guest, and a dead client can't stall the shared drain.
struct SerialPortBridgeTests {

	private func tempPath(_ tag: String, _ ext: String) -> String {
		NSTemporaryDirectory() + "mm-\(tag)-\(getpid())-\(UInt32.random(in: 0..<99999)).\(ext)"
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

		// A burst large enough that the drain writes to the dead fd before noticing EOF.
		for _ in 0..<50 { env.guestOut.write(Data(String(repeating: "x", count: 512).utf8)) }
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
}
