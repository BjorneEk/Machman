//
//  VMStatusDisplayTests.swift
//  MachmanTests
//
//  The state word every state spot shows: the VM's state, or "not responding" while its
//  vmhost misses the daemon's answer deadline (E20).
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
		#expect(vm(.running, unresponsive: true).stateLabel == "not responding")
		#expect(vm(.unknown, unresponsive: true).stateLabel == "not responding")
	}

	@Test func anAnsweringVMSaysItsState() {
		#expect(vm(.running, unresponsive: nil).stateLabel == "running")
		#expect(vm(.stopped, unresponsive: false).stateLabel == "stopped")
		#expect(vm(.starting, unresponsive: nil).stateLabel == "starting")
	}
}
