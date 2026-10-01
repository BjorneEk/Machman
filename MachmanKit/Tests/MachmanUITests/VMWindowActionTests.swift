//
//  VMWindowActionTests.swift
//  MachmanUITests
//
//  P27: the View menu, the picker and the menu-bar agent offer a window item only for a
//  running VM with an enabled display — Open, or Close once its window shows.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

struct VMWindowActionTests {
	private func vm(
		_ state: VMState, windowOpen: Bool = false, devices: [DeviceInfo]?
	) -> VMInfo {
		VMInfo(
			name: "alpha", state: state, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			windowOpen: windowOpen, devices: devices)
	}

	private let display = [DeviceInfo(kind: .keyboard), DeviceInfo(kind: .graphics)]

	@Test func aRunningVMWithADisplayOffersItsWindow() {
		#expect(vm(.running, devices: display).windowAction == .open)
		#expect(vm(.running, windowOpen: true, devices: display).windowAction == .close)
	}

	@Test func aVMWithoutADisplayOffersNone() {
		let disabled = [DeviceInfo(kind: .keyboard), DeviceInfo(kind: .graphics, enabled: false)]
		#expect(vm(.running, devices: disabled).windowAction == nil)
		#expect(vm(.running, devices: [DeviceInfo(kind: .keyboard)]).windowAction == nil)
	}

	@Test func aStoppedVMOffersNone() {
		#expect(vm(.stopped, devices: display).windowAction == nil)
		#expect(vm(.error, devices: display).windowAction == nil)
	}

	// A pre-1.0.4 daemon sends no device list; its VMs always had a display.
	@Test func anOldDaemonsVMCountsAsGraphical() {
		#expect(vm(.running, devices: nil).hasEnabledGraphics)
		#expect(vm(.running, devices: nil).windowAction == .open)
	}
}
