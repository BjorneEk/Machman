//
//  MachmanServer.swift
//  MachmanCore
//
//  Serves MachmanControlling over newline-framed JSON-RPC on a unix socket. Every request is
//  dispatched onto the main actor (where the engine lives); each connection can subscribe to
//  the event stream and receives events as id-less "event" notifications.
//

import Foundation
import MachmanAPI

@MainActor
public final class MachmanServer {
	private let api: MachmanControlling
	private let socketPath: String
	private let daemonVersion: String
	private let acceptQueue = DispatchQueue(label: "machman.server.accept")
	private var listener: UDSListener?
	private var connections: [Int32: Client] = [:]

	private final class Client {
		let connection: UDSConnection
		var eventTask: Task<Void, Never>?

		init(connection: UDSConnection) {
			self.connection = connection
		}
	}

	public init(api: MachmanControlling, socketPath: String, daemonVersion: String) {
		self.api = api
		self.socketPath = socketPath
		self.daemonVersion = daemonVersion
	}

	public convenience init(api: MachmanControlling, daemonVersion: String) {
		self.init(api: api, socketPath: machmanSocketPath(), daemonVersion: daemonVersion)
	}

	public func start() throws {
		guard listener == nil else { return }
		// $TMPDIR/<suite>/ is created on demand; it won't survive a reboot.
		ensureDirectory((socketPath as NSString).deletingLastPathComponent)
		listener = try UDSListener(path: socketPath, queue: acceptQueue) { [weak self] fd in
			Task { @MainActor [weak self] in
				self?.accept(fd)
			}
		}
		MachmanLogger.log(.log, "serving \(socketPath)")
	}

	public func stop() {
		listener?.shutdown()
		listener = nil
		for client in connections.values {
			client.eventTask?.cancel()
			client.connection.shutdown()
		}
		connections.removeAll()
	}

	private func accept(_ fd: Int32) {
		let connection = UDSConnection(fd: fd)
		let client = Client(connection: connection)
		connections[fd] = client
		connection.onLine = { [weak self] line in
			Task { @MainActor [weak self] in
				await self?.handle(line: line, client: client)
			}
		}
		connection.onClose = { [weak self] in
			Task { @MainActor [weak self] in
				self?.connections[fd]?.eventTask?.cancel()
				self?.connections[fd] = nil
			}
		}
		connection.start()
	}

	// MARK: - Dispatch

	private func handle(line: Data, client: Client) async {
		let peek: RPCPeek
		do {
			peek = try MachmanWire.decoder().decode(RPCPeek.self, from: line)
		} catch {
			send(client, RPCErrorReply(id: nil, error: RPCErrorBody(
				code: JSONRPC.parseError, message: "unparseable request")))
			return
		}
		guard let methodName = peek.method, peek.id != nil || peek.isNotification else {
			send(client, RPCErrorReply(id: peek.id, error: RPCErrorBody(
				code: JSONRPC.invalidRequest, message: "not a request")))
			return
		}
		guard let method = RPCMethod(rawValue: methodName), method != .event else {
			send(client, RPCErrorReply(id: peek.id, error: RPCErrorBody(
				code: JSONRPC.methodNotFound, message: "unknown method '\(methodName)'")))
			return
		}
		guard let id = peek.id else { return }   // client notifications: nothing to do

		do {
			switch method {
			case .hello:
				reply(client, id, RPCResults.Hello(
					apiVersion: MachmanProtocol.apiVersion, daemonVersion: daemonVersion))
			case .hostCapabilities:
				reply(client, id, try await api.hostCapabilities())
			case .vmList:
				reply(client, id, try await api.listVMs())
			case .vmGet:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.vm(named: p.name))
			case .vmCreate:
				reply(client, id, try await api.createVM())
			case .vmDelete:
				let p: RPCParams.Name = try params(line)
				try await api.deleteVM(named: p.name)
				reply(client, id, RPCEmpty())
			case .vmRename:
				let p: RPCParams.Rename = try params(line)
				try await api.renameVM(named: p.name, to: p.newName)
				reply(client, id, RPCEmpty())
			case .setHardware:
				let p: RPCParams.SetHardware = try params(line)
				try await api.setHardware(
					vm: p.name, cpuCount: p.cpuCount, memoryBytes: p.memoryBytes)
				reply(client, id, RPCEmpty())
			case .diskAdd:
				let p: RPCParams.AddDisk = try params(line)
				try await api.addDisk(vm: p.name, p.disk)
				reply(client, id, RPCEmpty())
			case .diskRemove:
				let p: RPCParams.RemoveDisk = try params(line)
				try await api.removeDisk(vm: p.name, diskID: p.diskID)
				reply(client, id, RPCEmpty())
			case .mountAdd:
				let p: RPCParams.AddMount = try params(line)
				try await api.addMount(vm: p.name, path: p.path, tag: p.tag)
				reply(client, id, RPCEmpty())
			case .mountRemove:
				let p: RPCParams.RemoveMount = try params(line)
				try await api.removeMount(vm: p.name, mountID: p.mountID)
				reply(client, id, RPCEmpty())
			case .setKernelBoot:
				let p: RPCParams.SetKernelBoot = try params(line)
				try await api.setKernelBoot(vm: p.name, enabled: p.enabled)
				reply(client, id, RPCEmpty())
			case .updateKernelSettings:
				let p: RPCParams.UpdateKernelSettings = try params(line)
				try await api.updateKernelSettings(vm: p.name, p.settings)
				reply(client, id, RPCEmpty())
			case .start:
				let p: RPCParams.Start = try params(line)
				try await api.start(vm: p.name, options: p.options ?? StartOptions())
				reply(client, id, RPCEmpty())
			case .stop:
				let p: RPCParams.Stop = try params(line)
				try await api.stop(vm: p.name, mode: p.mode)
				reply(client, id, RPCEmpty())
			case .consoleOpen:
				let p: RPCParams.Name = try params(line)
				try await api.openConsole(vm: p.name)
				reply(client, id, RPCEmpty())
			case .consoleClose:
				let p: RPCParams.Name = try params(line)
				try await api.closeConsole(vm: p.name)
				reply(client, id, RPCEmpty())
			case .consoleInfo:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.consoleInfo(vm: p.name))
			case .preview:
				let p: RPCParams.Preview = try params(line)
				if let data = try await api.preview(vm: p.name, maxWidth: p.maxWidth) {
					reply(client, id, RPCResults.Preview(jpegBase64: data.base64EncodedString()))
				} else {
					reply(client, id, JSONNull())
				}
			case .installStart:
				let p: RPCParams.InstallStart = try params(line)
				try await api.startMacInstall(vm: p.name, source: p.source)
				reply(client, id, RPCEmpty())
			case .installCancel:
				let p: RPCParams.Name = try params(line)
				try await api.cancelMacInstall(vm: p.name)
				reply(client, id, RPCEmpty())
			case .installPhase:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.macInstallPhase(vm: p.name))
			case .eventsSubscribe:
				subscribe(client)
				reply(client, id, RPCEmpty())
			case .event:
				break   // unreachable (rejected above)
			}
		} catch let error as ParamsError {
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(
				code: JSONRPC.invalidParams, message: error.message)))
		} catch let error as MachmanError {
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(error)))
		} catch {
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(
				code: JSONRPC.applicationError, message: "\(error)")))
		}
	}

	private func subscribe(_ client: Client) {
		guard client.eventTask == nil else { return }
		client.eventTask = Task { [weak self, weak client] in
			guard let stream = await self?.api.events() else { return }
			for await event in stream {
				guard let client = client else { return }
				self?.send(client, RPCCall(id: nil, method: RPCMethod.event.rawValue, params: event))
			}
		}
	}

	// MARK: - Encoding helpers

	private struct ParamsError: Error {
		let message: String
	}

	private func params<P: Codable>(_ line: Data) throws -> P {
		do {
			let call = try MachmanWire.decoder().decode(RPCCall<P>.self, from: line)
			guard let params = call.params else {
				throw ParamsError(message: "missing params")
			}
			return params
		} catch let error as ParamsError {
			throw error
		} catch {
			throw ParamsError(message: "invalid params: \(error)")
		}
	}

	private func reply<R: Codable>(_ client: Client, _ id: RPCID, _ result: R) {
		send(client, RPCResult(id: id, result: result))
	}

	private func send<T: Encodable>(_ client: Client, _ payload: T) {
		guard let data = try? MachmanWire.encoder().encode(payload) else { return }
		client.connection.send(data)
	}
}
