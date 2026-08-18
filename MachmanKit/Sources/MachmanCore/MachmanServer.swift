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
	// Startup-reconciliation gate: while set and unfinished, requests park before dispatch.
	// The socket must be claimed FIRST (it is the daemon mutex), but the engine's view is
	// wrong until adoption completes — a surviving vmhost's VM lists as stopped, vm.stop
	// "succeeds" doing nothing, vm.delete removes the directory under a live guest. A
	// reconnect-looping client lands requests in that gap routinely after a daemon
	// upgrade. hello and daemon.retire stay ungated: the version handshake and the
	// replace-older takeover must answer even if reconciliation wedges on a stuck vmhost.
	private var readyGate: Task<Void, Never>?

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

	// Call right after start(), in the same synchronous stretch: accepted connections
	// dispatch onto the main actor, so nothing can slip past a gate set before the current
	// block returns.
	public func holdRequests(until task: Task<Void, Never>) {
		readyGate = task
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
			// JSON-RPC 2.0: a notification (no id) is never answered, even one naming an
			// unknown method — log it instead so the client mistake stays visible.
			guard let id = peek.id else {
				MachmanLogger.log(.passiveWarning,
					"dropped notification for unknown method '\(methodName)'")
				return
			}
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(
				code: JSONRPC.methodNotFound, message: "unknown method '\(methodName)'")))
			return
		}
		guard let id = peek.id else { return }   // client notifications: nothing to do
		if method != .hello, method != .daemonRetire {
			await readyGate?.value
		}

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
				// Params are optional here (the method predates them): absent = nil template.
				let p: RPCParams.Create? = try? params(line)
				reply(client, id, try await api.createVM(template: p?.template))
			case .vmDelete:
				let p: RPCParams.Name = try params(line)
				try await api.deleteVM(named: p.name)
				reply(client, id, RPCEmpty())
			case .vmRename:
				let p: RPCParams.Rename = try params(line)
				try await api.renameVM(named: p.name, to: p.newName)
				reply(client, id, RPCEmpty())
			case .vmCopy:
				let p: RPCParams.Copy = try params(line)
				// Absent regenerateMAC means TRUE: a duplicate silently keeping its MAC would
				// walk straight into the macConflict refusal.
				reply(client, id, try await api.copyVM(
					vm: p.name, newName: p.newName, diskIDs: p.diskIDs,
					regenerateMAC: p.regenerateMAC ?? true))
			case .setHardware:
				let p: RPCParams.SetHardware = try params(line)
				try await api.setHardware(
					vm: p.name, cpuCount: p.cpuCount, memoryBytes: p.memoryBytes,
					nestedVirtualization: p.nestedVirtualization)
				reply(client, id, RPCEmpty())
			case .regenerateMAC:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.regenerateMAC(vm: p.name))
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
				try await api.addMount(vm: p.name, path: p.path, tag: p.tag, kind: p.kind)
				reply(client, id, RPCEmpty())
			case .mountRemove:
				let p: RPCParams.RemoveMount = try params(line)
				try await api.removeMount(vm: p.name, mountID: p.mountID)
				reply(client, id, RPCEmpty())
			case .diskImport:
				let p: RPCParams.ImportDisk = try params(line)
				reply(client, id, try await api.importDisk(vm: p.name, path: p.path))
			case .diskPromote:
				let p: RPCParams.RemoveDisk = try params(line)
				reply(client, id, try await api.promoteDisk(vm: p.name, diskID: p.diskID))
			case .setKernelBoot:
				let p: RPCParams.SetKernelBoot = try params(line)
				try await api.setKernelBoot(vm: p.name, enabled: p.enabled)
				reply(client, id, RPCEmpty())
			case .updateKernelSettings:
				let p: RPCParams.UpdateKernelSettings = try params(line)
				try await api.updateKernelSettings(vm: p.name, p.settings)
				reply(client, id, RPCEmpty())
			case .kernelPromote:
				let p: RPCParams.PromoteKernel = try params(line)
				reply(client, id, try await api.promoteKernelFile(
					vm: p.name, role: p.role, sourcePath: p.sourcePath, tag: p.tag))
			case .kernelDelete:
				let p: RPCParams.DeleteKernel = try params(line)
				reply(client, id, try await api.deleteKernelFile(vm: p.name, path: p.path))
			case .setStartPolicy:
				let p: RPCParams.SetStartPolicy = try params(line)
				try await api.setStartPolicy(vm: p.name, policy: p.policy)
				reply(client, id, RPCEmpty())
			case .setSafety:
				let p: RPCParams.SetSafety = try params(line)
				try await api.setSafety(vm: p.name, disks: p.disks, mounts: p.mounts)
				reply(client, id, RPCEmpty())
			case .start:
				let p: RPCParams.Start = try params(line)
				try await api.start(vm: p.name, options: p.options ?? StartOptions())
				reply(client, id, RPCEmpty())
			case .stop:
				let p: RPCParams.Stop = try params(line)
				try await api.stop(vm: p.name, mode: p.mode)
				reply(client, id, RPCEmpty())
			case .consoleAdd:
				let p: RPCParams.Name = try params(line)
				try await api.addConsolePort(vm: p.name)
				reply(client, id, RPCEmpty())
			case .consoleRemove:
				let p: RPCParams.Name = try params(line)
				try await api.removeConsolePort(vm: p.name)
				reply(client, id, RPCEmpty())
			case .uartAdd:
				let p: RPCParams.Name = try params(line)
				try await api.addUartPort(vm: p.name)
				reply(client, id, RPCEmpty())
			case .uartRemove:
				let p: RPCParams.Name = try params(line)
				try await api.removeUartPort(vm: p.name)
				reply(client, id, RPCEmpty())
			case .serialSetLogging:
				let p: RPCParams.SetSerialLogging = try params(line)
				try await api.setSerialLogging(
					vm: p.name, kind: p.kind, index: p.index, config: p.config)
				reply(client, id, RPCEmpty())
			case .windowOpen:
				let p: RPCParams.Name = try params(line)
				try await api.openWindow(vm: p.name)
				reply(client, id, RPCEmpty())
			case .windowClose:
				let p: RPCParams.Name = try params(line)
				try await api.closeWindow(vm: p.name)
				reply(client, id, RPCEmpty())
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
			case .deviceAdd:
				let p: RPCParams.DeviceMutation = try params(line)
				reply(client, id, try await api.addDevice(vm: p.name, kind: p.kind))
			case .deviceRemove:
				let p: RPCParams.DeviceMutation = try params(line)
				reply(client, id, try await api.removeDevice(vm: p.name, kind: p.kind))
			case .deviceUpdate:
				let p: RPCParams.DeviceUpdate = try params(line)
				reply(client, id, try await api.updateDevice(vm: p.name, device: p.device))
			case .setEnabled:
				let p: RPCParams.SetEnabled = try params(line)
				try await api.setEnabled(
					vm: p.name, disks: p.disks, mounts: p.mounts,
					console: p.console, uart: p.uart)
				reply(client, id, RPCEmpty())
			case .kernelSetOverride:
				let p: RPCParams.KernelOverride = try params(line)
				reply(client, id, try await api.setKernelOverride(
					vm: p.name, path: p.path, commandLine: p.commandLine,
					overrideEnabled: p.overrideEnabled))
			case .diskResize:
				let p: RPCParams.ResizeDisk = try params(line)
				reply(client, id, try await api.resizeDisk(
					vm: p.name, diskID: p.diskID, sizeBytes: p.sizeBytes))
			case .diskRename:
				let p: RPCParams.RenameDisk = try params(line)
				reply(client, id, try await api.renameDisk(
					vm: p.name, diskID: p.diskID, newName: p.newName))
			case .mountSetTag:
				let p: RPCParams.SetMountTag = try params(line)
				reply(client, id, try await api.setMountTag(
					vm: p.name, mountID: p.mountID, tag: p.tag))
			case .kernelRename:
				let p: RPCParams.RenameKernel = try params(line)
				reply(client, id, try await api.renameKernelFile(
					vm: p.name, path: p.path, tag: p.tag))
			case .sshSet:
				let p: RPCParams.SSHSet = try params(line)
				reply(client, id, try await api.setSSH(
					vm: p.name, integrationEnabled: p.integrationEnabled,
					reverseApproved: p.reverseApproved, alias: p.alias))
			case .sshRefresh:
				let p: RPCParams.Name = try params(line)
				try await api.refreshSSH(vm: p.name)
				reply(client, id, RPCEmpty())
			case .sshReset:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.resetSSH(vm: p.name))
			case .mountSetKind:
				let p: RPCParams.SetMountKind = try params(line)
				reply(client, id, try await api.setMountKind(
					vm: p.name, mountID: p.mountID, kind: p.kind))
			case .setupReset:
				let p: RPCParams.Name = try params(line)
				reply(client, id, try await api.resetSetup(vm: p.name))
			case .setupServe:
				let p: RPCParams.SetupServe = try params(line)
				reply(client, id, try await api.setSetupServed(vm: p.name, serve: p.serve))
			case .hostOperations:
				reply(client, id, try await api.operations())
			case .operationCancel:
				let p: RPCParams.CancelOperation = try params(line)
				try await api.cancelOperation(id: p.id)
				reply(client, id, RPCEmpty())
			case .installRosetta:
				try await api.installRosetta()
				reply(client, id, RPCEmpty())
			case .eventsSubscribe:
				subscribe(client)
				reply(client, id, RPCEmpty())
			case .safeSave:
				let p: RPCParams.Rename = try params(line)
				reply(client, id, try await api.safeSave(vm: p.name, to: p.newName))
			case .daemonRetire:
				try await api.retire()
				reply(client, id, RPCEmpty())
			case .event:
				break   // unreachable (rejected above)
			}
		} catch let error as ParamsError {
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(
				code: JSONRPC.invalidParams, message: error.message)))
		} catch let VirtualMachineError.critical(message) {
			// Engine internals that escaped untyped: keep a machmanCode and stop leaking Swift
			// enum syntax ("critical(...)") onto the wire.
			send(client, RPCErrorReply(id: id, error: RPCErrorBody(
				MachmanError(code: .internalError, message: message))))
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
