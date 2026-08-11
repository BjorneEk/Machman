//
//  VMRuntime.swift
//  Machman
//
//  The live half of one VM: owns the VZVirtualMachine, is its delegate, derives the API-level
//  state and broadcasts changes. Knows nothing about windows (WindowPresenter) or the VM list
//  (VMRegistry). Main-actor because VZVirtualMachine created on the main queue must be driven
//  from it.
//

import Foundation
import Virtualization
import MachmanAPI

@MainActor
final class VMRuntime: NSObject, VZVirtualMachineDelegate {
	let config: VMConfig
	private let events: EventBus
	private(set) var vz: VZVirtualMachine?
	private var stateObservation: NSKeyValueObservation?
	private var lastEmitted: VMState = .stopped
	// One data-plane bridge per serial port, live while the VM runs.
	private var serialBridges: [SerialPortBridge] = []
	// Called exactly once, after the VZ machine is gone (guest stop, forced stop, or crash).
	var onTeardown: (() -> Void)?

	init(config: VMConfig, events: EventBus) {
		self.config = config
		self.events = events
		super.init()
	}

	var state: VMState {
		guard let vz = vz else { return .stopped }
		return Self.map(vz.state)
	}

	nonisolated static func map(_ state: VZVirtualMachine.State) -> VMState {
		switch state {
		case .stopped: return .stopped
		case .running: return .running
		case .paused: return .paused
		case .error: return .error
		case .starting: return .starting
		case .pausing: return .paused
		case .resuming: return .starting
		case .stopping: return .stopping
		case .saving: return .paused
		case .restoring: return .starting
		@unknown default: return .unknown
		}
	}

	func start() async throws {
		guard vz == nil else {
			throw VirtualMachineError.critical("\(config.name) is already running")
		}
		let built = try config.makeVZVirtualMachineConfiguration()
		let machine = VZVirtualMachine(configuration: built.configuration)
		machine.delegate = self
		vz = machine
		startSerialBridges(built.serialWiring)
		stateObservation = machine.observe(\.state, options: [.new]) { [weak self] machine, _ in
			let mapped = VMRuntime.map(machine.state)
			Task { @MainActor [weak self] in
				self?.emitState(mapped)
			}
		}
		emitState(.starting)
		do {
			try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
				machine.start { result in
					cont.resume(with: result)
				}
			}
		} catch {
			teardown()
			throw error
		}
	}

	// Ask the guest OS to shut itself down. The guest may take a while (or ignore it);
	// completion arrives as a normal guestDidStop.
	func requestSoftStop() throws {
		guard let vz = vz else {
			throw MachmanError(code: .invalidState, message: "\(config.name) is not running")
		}
		guard vz.canRequestStop else {
			throw MachmanError(
				code: .invalidState,
				message: "\(config.name) cannot handle a shutdown request; use force stop")
		}
		try vz.requestStop()
	}

	func forceStop() async throws {
		guard let machine = vz else { return }
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			machine.stop { error in
				if let error = error {
					cont.resume(throwing: error)
				} else {
					cont.resume()
				}
			}
		}
		teardown()
	}

	nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		Task { @MainActor in
			self.teardown()
		}
	}

	nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
		Task { @MainActor in
			self.events.emit(.log(
				vm: self.config.name, level: .error,
				message: "\(self.config.name) stopped with error: \(error)"))
			self.teardown()
		}
	}

	private func emitState(_ state: VMState) {
		guard state != lastEmitted else { return }
		lastEmitted = state
		events.emit(.stateChanged(vm: config.name, state: state))
	}

	private func teardown() {
		guard vz != nil else { return }
		stateObservation?.invalidate()
		stateObservation = nil
		for bridge in serialBridges { bridge.stop() }
		serialBridges.removeAll()
		vz = nil
		emitState(.stopped)
		onTeardown?()
	}

	// MARK: - Serial data plane

	private func startSerialBridges(_ wiring: [SerialWiring]) {
		let runtimeDir = MachmanPaths.runtimeDir()
		for wire in wiring {
			let ports = wire.kind == .console ? config.consolePorts : config.uartPorts
			let logging = ports.indices.contains(wire.index)
				? ports[wire.index].logging : SerialLogConfig()
			let bridge = SerialPortBridge(
				kind: wire.kind, index: wire.index,
				socketPath: MachmanPaths.serialSocketPath(
					vm: config.name, kind: wire.kind.rawValue, index: wire.index,
					runtimeDir: runtimeDir),
				logURL: config.localURL(file: "serial-\(wire.kind.rawValue)\(wire.index).log"),
				logConfig: logging, toGuest: wire.toGuest, fromGuest: wire.fromGuest)
			bridge.start()
			serialBridges.append(bridge)
		}
	}

	// The actual bound socket path (stored, not recomputed — robust to a safe-run rename).
	func serialSocketPath(kind: SerialPortKind, index: Int) -> String? {
		serialBridges.first { $0.kind == kind && $0.index == index }?.socketPath
	}

	func retuneSerialLogging(kind: SerialPortKind, index: Int, config: SerialLogConfig) {
		serialBridges.first { $0.kind == kind && $0.index == index }?.retune(config)
	}
}
