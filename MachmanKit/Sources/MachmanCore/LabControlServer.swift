//
//  LabControlServer.swift
//  MachmanCore
//
//  Serves the lab's control protocol (LabCommand) on a UNIX socket: one line in, one line
//  out, answered in order per connection. Only a test-suite agent starts one, and only at
//  the path MACHMAN_LAB_AGENT_CONTROL names inside its run's sandbox (LabEnvironment); the
//  socket is its owner's only (BoundSocket), like the daemon's own.
//

import Foundation
import MachmanAPI

@MainActor
public final class LabControlServer {
	private let handler: @MainActor (LabCommand) async -> String
	private let acceptQueue = DispatchQueue(label: "machman.lab.control.accept")
	private var listener: UDSListener?
	// Keyed by a per-accept counter, never by descriptor (MachmanServer's E13 lesson).
	private var connections: [Int: UDSConnection] = [:]
	// Each connection's last reply in flight: the next line waits for it, so replies keep
	// their lines' order even when one command takes longer.
	private var tails: [Int: Task<Void, Never>] = [:]
	private var nextID = 0

	// Throws UDSError.alreadyRunning when another process serves `path`.
	public init(path: String, handler: @escaping @MainActor (LabCommand) async -> String) throws {
		self.handler = handler
		listener = try UDSListener(path: path, queue: acceptQueue) { [weak self] fd in
			Task { @MainActor [weak self] in
				guard let self else {
					close(fd)
					return
				}
				self.accept(fd)
			}
		}
		MachmanLogger.log(.log, "test mode: lab control on \(path)")
	}

	public func stop() {
		listener?.shutdown()
		listener = nil
		for connection in connections.values {
			connection.shutdown()
		}
		connections.removeAll()
		tails.values.forEach { $0.cancel() }
		tails.removeAll()
	}

	private func accept(_ fd: Int32) {
		let connection = UDSConnection(fd: fd)
		let id = nextID
		nextID += 1
		connections[id] = connection
		connection.onLine = { [weak self, weak connection] line in
			let text = String(decoding: line, as: UTF8.self)
			Task { @MainActor [weak self] in
				guard let self, let connection else { return }
				let previous = self.tails[id]
				self.tails[id] = Task { @MainActor [weak self] in
					await previous?.value
					guard let self else { return }
					connection.send(Data(await self.reply(to: text).utf8))
				}
			}
		}
		connection.onClose = { [weak self] in
			Task { @MainActor [weak self] in
				self?.connections.removeValue(forKey: id)
				self?.tails.removeValue(forKey: id)
			}
		}
		connection.start()
	}

	private func reply(to line: String) async -> String {
		switch LabCommand.parse(line) {
		case .success(let command): return await handler(command)
		case .failure(let error): return "error \(error.reason)"
		}
	}
}

extension VMHostQuitReason {
	// The reason a lab `quit` asks the agent to quit for.
	public init(lab reason: LabQuitReason) {
		switch reason {
		case .userQuit: self = .userQuit
		case .logOut: self = .logOut
		case .restart: self = .restart
		case .shutDown: self = .shutDown
		}
	}
}
