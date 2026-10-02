//
//  VMStatusDisplayTests.swift
//  MachmanTests
//
//  The state word every state spot shows: the VM's state as a word ("Running", never the
//  raw enum name — H8), or "Not responding" while its vmhost misses the daemon's answer
//  deadline (E20).
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

struct VMStatusDisplayTests {
	private func vm(_ state: VMState, unresponsive: Bool?) -> VMInfo {
		VMInfo(
			name: "alpha", state: state, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			unresponsive: unresponsive)
	}

	@Test func aStalledVMSaysNotResponding() {
		#expect(vm(.running, unresponsive: true).stateLabel == "Not responding")
		#expect(vm(.unknown, unresponsive: true).stateLabel == "Not responding")
	}

	@Test func anAnsweringVMSaysItsState() {
		#expect(vm(.running, unresponsive: nil).stateLabel == "Running")
		#expect(vm(.stopped, unresponsive: false).stateLabel == "Stopped")
		#expect(vm(.starting, unresponsive: nil).stateLabel == "Starting")
	}

	@Test func everyStateHasADisplayWord() {
		#expect(VMState.allCases.map(\.displayLabel)
			== ["Stopped", "Starting", "Running", "Stopping", "Paused", "Error", "Unknown"])
	}

	// W4: the toolbar said "Stopping…" and the canvas "Shutting down…"; both use this now.
	@Test func transitionsShowTheirWordWithAnEllipsis() {
		#expect(VMState.starting.progressLabel == "Starting\u{2026}")
		#expect(VMState.stopping.progressLabel == "Stopping\u{2026}")
		let settled = VMState.allCases.filter { $0 != .starting && $0 != .stopping }
		#expect(settled.allSatisfy { $0.progressLabel == nil })
	}
}
