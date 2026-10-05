//
//  TGDesktop.swift
//  MachmanLabTests
//
//  The desktop's client stack (VMStore, OperationsStore, TerminalSessions, the canvas and
//  profile stores, VMListViewModel) wired as DaemonConnection wires it, but over the lab
//  agent's socket: the desktop rows run the desktop's own view-model code against real
//  processes. No window and no AppKit service: the stores write under the scope, the preview
//  service is never attached (no capture), and each terminal is a LabConsole on the tab's
//  socket instead of a SwiftTerm view.
//

import Foundation
import MachmanAPI
import MachmanClient
import MachmanDesktopCore
import MachmanTestSupport
import MachmanUI

/// A terminal tab's controller: connects a LabConsole to the socket the tab is given.
@MainActor
final class TGConsoleController: TerminalController {
	private(set) var connected = false
	let startupSignature: TerminalStartupSignature
	private(set) var connectedPaths: [String] = []
	private(set) var notes: [String] = []
	private let label: String
	private var opening: Task<LabConsole, Error>?

	init(profile: TerminalProfile, label: String) {
		startupSignature = profile.startupSignature
		self.label = label
	}

	private var transcriptName: String { "\(label)-\(connectedPaths.count)" }

	/// Opens in a Task: the main actor never blocks on a socket.
	func connect(path: String) {
		connectedPaths.append(path)
		connected = true
		let name = transcriptName
		opening = Task { try await LabConsole.connect(path, transcript: name) }
	}

	// No ssh session in these rows: a stream is never started.
	func connect(stream: TerminalByteStream) { connected = false }

	func disconnect() {
		connected = false
		if let opening { Task { (try? await opening.value)?.close() } }
	}

	func applyLive(_ profile: TerminalProfile) {}
	func note(_ text: String) { notes.append(text) }

	/// What this tab's console received so far (the live connection's transcript).
	func transcript() -> Data {
		(try? Data(contentsOf: URL(fileURLWithPath: Lab.transcriptsDir + "/\(transcriptName).log")))
			?? Data()
	}

	func console() async throws -> LabConsole {
		guard let opening else {
			throw LabError.consoleUnavailable("\(label) never connected")
		}
		return try await opening.value
	}
}

@MainActor
final class TGDesktop {
	let api: RemoteMachman
	let store = VMStore()
	let operations = OperationsStore()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	private(set) var controllers: [TGConsoleController] = []
	private(set) var terminals: TerminalSessions!
	private(set) var viewModel: VMListViewModel!

	private init(api: RemoteMachman, scope: LabScope) {
		self.api = api
		let dir = URL(fileURLWithPath: scope.dir + "/desktop-" + TG.nonce())
		canvases = CanvasStateStore(fileURL: dir.appendingPathComponent("Canvas.json"))
		profiles = TerminalProfileStore(fileURL: dir.appendingPathComponent("Profiles.json"))
		previews = PreviewService(store: store)
		let prefix = scope.id + "-desktop-" + TG.nonce()
		terminals = TerminalSessions { [unowned self] profile in
			let controller = TGConsoleController(
				profile: profile, label: "\(prefix)-\(self.controllers.count)")
			self.controllers.append(controller)
			return controller
		}
		store.attach(api: api)
		operations.attach(api: api)
		viewModel = VMListViewModel(
			api: api, store: store, operations: operations, terminals: terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
	}

	/// The desktop once its first list shows `vm`.
	static func make(api: RemoteMachman, scope: LabScope, showing vm: String) async throws
		-> TGDesktop {
		let desktop = TGDesktop(api: api, scope: scope)
		guard await eventually(timeout: .seconds(20), { desktop.vm(vm) != nil }) else {
			throw LabError.specInvalid("the desktop's list never showed \(vm)")
		}
		return desktop
	}

	func vm(_ name: String) -> VMInfo? { viewModel.vms.first { $0.name == name } }

	/// Waits until the desktop's own list shows `name` in `state`.
	func waitFor(_ name: String, _ state: VMState, timeout: Duration = .seconds(60)) async
		-> Bool {
		await eventually(timeout: timeout) { self.vm(name)?.state == state }
	}

	/// Opens a console tab the way the canvas does — the tab in the VM's layout, then the
	/// controller on the port's socket — and returns its controller.
	func openConsole(vm name: String, port: Int = 0) async throws -> TGConsoleController {
		let ref = SerialPortRef(kind: .console, index: port)
		var canvas = canvases.canvas(for: name)
		canvas.open(.terminal(ref))
		canvases.setCanvas(canvas, for: name)
		guard await eventually(timeout: .seconds(20), {
			self.vm(name)?.consolePorts?.first { $0.index == port }?.socketPath != nil
		}), let path = vm(name)?.consolePorts?.first(where: { $0.index == port })?.socketPath
		else { throw LabError.consoleUnavailable("\(name) lists no console \(port) socket") }
		terminals.ensureController(
			vm: name, ref: ref, socketPath: path, profile: profiles.profile(vm: name, ref: ref))
		guard await eventually({ self.terminals.controller(vm: name, ref: ref) != nil }),
			let controller = terminals.controller(vm: name, ref: ref) as? TGConsoleController
		else { throw LabError.consoleUnavailable("no controller for \(name)'s console \(port)") }
		return controller
	}
}
