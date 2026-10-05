//
//  ScriptedPeer.swift
//  MachmanClientTests
//
//  The far end of one client connection, over a real unix socket in the run's scratch: it
//  accepts ONE connection, records every request (id, method, params as JSON), answers
//  machman.hello itself with a chosen apiVersion (nil: never), and answers or drops
//  everything else only when the test says so. Everything the reader thread touches is
//  lock-guarded.
//

import Foundation
import MachmanAPI
import MachmanTestSupport

final class ScriptedPeer: @unchecked Sendable {
	struct Request: Equatable {
		let id: Int
		let method: String
		let params: String?   // the params re-serialized with sorted keys; nil when absent
	}

	let socketPath: String
	private let listenFD: Int32
	private let helloAPIVersion: Int?
	private let lock = NSLock()
	private var connFD: Int32 = -1
	private var requests: [Request] = []
	private var buffer = Data()

	init(helloAPIVersion: Int? = MachmanProtocol.apiVersion) throws {
		self.helloAPIVersion = helloAPIVersion
		socketPath = TestEnvironment.socketPath("mm-sp")
		listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(listenFD, 4) == 0 else {
			Darwin.close(listenFD)
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		let fd = listenFD
		Thread.detachNewThread { [weak self] in
			let conn = accept(fd, nil, nil)
			guard conn >= 0 else { return }
			self?.setConnection(conn)
			var chunk = [UInt8](repeating: 0, count: 4096)
			while true {
				let n = read(conn, &chunk, chunk.count)
				if n <= 0 { break }
				self?.ingest(Data(chunk[0..<n]))
			}
			// The reader is the descriptor's last holder: dropConnection only shuts it down,
			// so the number is never reused under a blocked read or a late reply.
			self?.setConnection(-1)
			Darwin.close(conn)
		}
	}

	// Every request seen so far, oldest first.
	var seen: [Request] {
		lock.withLock { requests }
	}

	// Wait (bounded, 5 s) until the peer has seen `count` requests.
	func waitForRequests(_ count: Int) async {
		for _ in 0..<200 {
			if seen.count >= count { return }
			try? await Task.sleep(for: .milliseconds(25))
		}
	}

	// Answer one request with `resultJSON` as its result.
	func reply(id: Int, resultJSON: String = "{}") {
		send(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#)
	}

	// Any line, as written: a reply or event the typed helpers don't make.
	func sendLine(_ line: String) {
		send(line)
	}

	// The peer goes away mid-connection: the client reads EOF.
	func dropConnection() {
		lock.withLock {
			if connFD >= 0 { _ = Darwin.shutdown(connFD, SHUT_RDWR) }
		}
	}

	func close() {
		dropConnection()
		Darwin.close(listenFD)
		unlink(socketPath)
	}

	// MARK: - Reader side

	private func setConnection(_ fd: Int32) {
		if fd >= 0 {
			// A reply to a client that already left fails with EPIPE, never SIGPIPE.
			var on: Int32 = 1
			_ = setsockopt(
				fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		}
		lock.withLock { connFD = fd }
	}

	private func ingest(_ data: Data) {
		var hellos: [Int] = []
		lock.withLock {
			buffer.append(data)
			while let newline = buffer.firstIndex(of: 0x0A) {
				let line = buffer.subdata(in: buffer.startIndex..<newline)
				buffer.removeSubrange(buffer.startIndex...newline)
				guard let object = try? JSONSerialization.jsonObject(with: line)
						as? [String: Any],
					let id = object["id"] as? Int,
					let method = object["method"] as? String else { continue }
				requests.append(Request(
					id: id, method: method, params: Self.json(object["params"])))
				if method == RPCMethod.hello.rawValue { hellos.append(id) }
			}
		}
		guard let apiVersion = helloAPIVersion else { return }
		for id in hellos {
			reply(
				id: id,
				resultJSON: #"{"apiVersion":\#(apiVersion),"daemonVersion":"9.9.9"}"#)
		}
	}

	private static func json(_ value: Any?) -> String? {
		guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
		else { return nil }
		return String(decoding: data, as: UTF8.self)
	}

	private func send(_ line: String) {
		lock.withLock {
			guard connFD >= 0 else { return }
			let payload = line + "\n"
			_ = payload.withCString { write(connFD, $0, strlen($0)) }
		}
	}
}
