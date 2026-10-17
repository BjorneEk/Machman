//
//  VMConfig+Serial.swift
//  MachmanCore
//
//  Serial ports (console and uart): adding and removing them within the framework's port
//  budget, each port's log file, and its logging settings with their cap.
//

import Foundation
import MachmanAPI

extension VMConfig {
	// MARK: - Serial ports (console + uart)

	// The framework caps a VM at 10 virtio serial-port devices; console + uart share that budget.
	static let maxSerialPorts = 10

	private func ensureSerialCapacity() throws {
		guard consolePorts.count + uartPorts.count < Self.maxSerialPorts else {
			throw MachmanError(
				code: .invalidArgument,
				message: "A VM can have at most \(Self.maxSerialPorts) serial ports")
		}
	}

	func addConsolePort() throws {
		try ensureSerialCapacity()
		consolePorts.append(SerialPort())
		try saveVMConfig()
	}

	func removeLastConsolePort() throws {
		guard !consolePorts.isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no console ports")
		}
		consolePorts.removeLast()
		try saveVMConfig()
		removeSerialLog(kind: .console, index: consolePorts.count)
	}

	func addUartPort() throws {
		try ensureSerialCapacity()
		uartPorts.append(SerialPort())
		try saveVMConfig()
	}

	func removeLastUartPort() throws {
		guard !uartPorts.isEmpty else {
			throw MachmanError(code: .invalidArgument, message: "\(name) has no UART ports")
		}
		uartPorts.removeLast()
		try saveVMConfig()
		removeSerialLog(kind: .uart, index: uartPorts.count)
	}

	// The per-port log file, derived one way for every consumer: the bridge writes it, the
	// registry reports it, and port removal deletes it.
	func serialLogURL(kind: SerialPortKind, index: Int) -> URL {
		localURL(file: "serial-\(kind.rawValue)\(index).log")
	}

	// Ports only remove from the end, so the dropped index is exactly the new count — its
	// log dies with it, and a port added later at the same index starts fresh. Best-effort:
	// removal happens while the VM is stopped (add/remove refuse while hosted), so nothing
	// holds the file open, but a failed unlink must not fail the config edit.
	private func removeSerialLog(kind: SerialPortKind, index: Int) {
		try? FileManager.default.removeItem(at: serialLogURL(kind: kind, index: index))
	}

	// The largest serial log cap vm.serial.setLogging accepts (E23): a trim reads up to twice the
	// cap into the vmhost's memory, and a cap of 2^63 or more overflowed the bridge. 0 and nil
	// both mean no cap.
	static let serialLogMaxBytesLimit: UInt64 = 1 << 30

	func setSerialLogging(kind: SerialPortKind, index: Int, config: SerialLogConfig) throws {
		let ports: ReferenceWritableKeyPath<VMConfig, [SerialPort]>
		switch kind {
		case .console:
			guard consolePorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "\(name) has no console port \(index)")
			}
			ports = \.consolePorts
		case .uart:
			guard uartPorts.indices.contains(index) else {
				throw MachmanError(code: .notFound, message: "\(name) has no UART port \(index)")
			}
			ports = \.uartPorts
		case .unknown:
			throw MachmanError(code: .invalidArgument, message: "Unknown serial port kind")
		}
		// Checked as a cap enters: a larger one the port already holds (written by a script)
		// keeps working, and clients send it back unchanged with every other logging edit.
		if let cap = config.maxBytes, cap > Self.serialLogMaxBytesLimit,
			cap != self[keyPath: ports][index].logging.maxBytes {
			throw MachmanError(
				code: .invalidArgument,
				message: "A serial log can be capped at 1 GB at most")
		}
		self[keyPath: ports][index].logging = config
		try saveVMConfig()
	}
}
