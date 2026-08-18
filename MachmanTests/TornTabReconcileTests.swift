//
//  TornTabReconcileTests.swift
//  MachmanTests
//
//  The torn-tab staleness rule behind the list-refresh reconcile (T6): which torn windows
//  a fresh VM list invalidates. Pure value rules — the dismissal itself is SwiftUI glue,
//  checked manually.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
@testable import MachmanDesktop

@MainActor
struct TornTabReconcileTests {

	private func makeVM(
		_ name: String, console: [Int] = [], uart: [Int] = []
	) -> VMInfo {
		var vm = VMInfo(
			name: name, state: .running, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil))
		vm.consolePorts = console.map {
			SerialPortInfo(kind: .console, index: $0, guestDevice: "hvc\($0)",
				logging: SerialLogConfig())
		}
		vm.uartPorts = uart.map {
			SerialPortInfo(kind: .uart, index: $0, guestDevice: "ttyAMA\($0)",
				logging: SerialLogConfig())
		}
		return vm
	}

	@Test func goneVMInvalidatesEveryTabKind() {
		let list = [makeVM("Debian", console: [0])]
		for tab: VMPaneTab in [
			.config,
			.terminal(SerialPortRef(kind: .console, index: 0)),
			.ssh(SSHSessionRef(title: "Session 1")),
		] {
			#expect(TornTab(vm: "Ghost", tab: tab).isStale(in: list))
			#expect(!TornTab(vm: "Debian", tab: .config).isStale(in: list))
		}
	}

	@Test func terminalFollowsItsExactPort() {
		let list = [makeVM("Debian", console: [0], uart: [0])]
		let console0 = TornTab(
			vm: "Debian", tab: .terminal(SerialPortRef(kind: .console, index: 0)))
		let console1 = TornTab(
			vm: "Debian", tab: .terminal(SerialPortRef(kind: .console, index: 1)))
		let uart0 = TornTab(vm: "Debian", tab: .terminal(SerialPortRef(kind: .uart, index: 0)))
		#expect(!console0.isStale(in: list))
		#expect(!uart0.isStale(in: list))
		#expect(console1.isStale(in: list))   // the removed port's tab goes

		// Removing the uart family strands only its terminal, not the console's.
		let shrunk = [makeVM("Debian", console: [0])]
		#expect(!console0.isStale(in: shrunk))
		#expect(uart0.isStale(in: shrunk))
	}

	@Test func sshAndConfigSurvivePortChanges() {
		// SSH sessions are local processes and config is always present: only the VM
		// vanishing invalidates them, never port edits.
		let noPorts = [makeVM("Debian")]
		#expect(!TornTab(vm: "Debian", tab: .config).isStale(in: noPorts))
		#expect(!TornTab(vm: "Debian", tab: .ssh(SSHSessionRef(title: "S")))
			.isStale(in: noPorts))
	}
}
