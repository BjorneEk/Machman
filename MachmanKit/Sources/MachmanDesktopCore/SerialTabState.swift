//
//  SerialTabState.swift
//  MachmanDesktopCore
//
//  What a serial tab can show (T10). Only a port with a socket has a terminal; every other
//  case says why there is none, so a running VM never reads "Start the VM": the port is
//  disabled, it was enabled after the start, the VM is still starting, or this Mac can't
//  attach it (a gated UART). Reads the served port as it is, so an open or restored tab
//  follows the list.
//

import Foundation
import MachmanAPI
import MachmanUI

public enum SerialTabState: Equatable {
	case live(socketPath: String)
	case waiting                    // the VM is starting; its bridges come up with it
	case startVM                    // stopped (or gone): a start attaches it
	case restartVM                  // enabled while the VM ran: attached at the next start
	case disabled(running: Bool)    // enable it, then (re)start the VM
	case unavailable(reason: String)   // this host can't attach it; the daemon's sentence

	// First match wins. A live socket beats everything: a port disabled mid-run stays
	// attached until the VM stops.
	public init(vm: VMInfo, ref: SerialPortRef) {
		let port = vm.port(for: ref)
		if let socket = port?.socketPath {
			self = .live(socketPath: socket)
		} else if let gate = port?.unavailable {
			self = .unavailable(reason: gate.message)
		} else if port?.enabled == false {
			let running = [.running, .paused, .starting].contains(vm.state)
			self = .disabled(running: running)
		} else if port == nil {
			self = .startVM
		} else {
			switch vm.state {
			case .starting: self = .waiting
			case .running, .paused: self = .restartVM
			case .stopping, .stopped, .error, .unknown: self = .startVM
			}
		}
	}
}
