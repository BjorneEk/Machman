//
//  StartIntentTests.swift
//  MachmanUITests
//
//  Decision 7 as one rule (P21): a plain Start follows the VM's start policy, and a named
//  item overrides only what it names. The Dock, the picker, the Run menu, the toolbar and the
//  menu-bar agent all send what this returns.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanUI

struct StartIntentTests {
	private func vm(_ policy: StartPolicy?) -> VMInfo {
		VMInfo(
			name: "alpha", state: .stopped, created: Date(timeIntervalSince1970: 1_700_000_000),
			lastRan: nil, cpuCount: 2, memoryBytes: 2_147_483_648, macAddress: nil,
			disks: [], mounts: [],
			boot: BootInfo(
				mode: .efi, kernel: nil, macInstallState: nil,
				minCPUCount: nil, minMemoryBytes: nil),
			startPolicy: policy)
	}

	@Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
	func plainFollowsThePolicy(windowed: Bool, safe: Bool) {
		let options = vm(StartPolicy(windowed: windowed, safe: safe)).startOptions()
		#expect(options == StartOptions(openWindow: windowed, force: false, safe: safe))
	}

	@Test func aPrePolicyDaemonsVMStartsWindowedAndUnsafe() {
		#expect(vm(nil).startOptions(.plain) == StartOptions(openWindow: true, safe: false))
	}

	@Test func headlessKeepsThePolicysSafety() {
		let safe = vm(StartPolicy(windowed: true, safe: true))
		#expect(safe.startOptions(.headless) == StartOptions(openWindow: false, safe: true))
		let plain = vm(StartPolicy(windowed: true, safe: false))
		#expect(plain.startOptions(.headless) == StartOptions(openWindow: false, safe: false))
	}

	@Test func safeKeepsThePolicysWindowMode() {
		let headless = vm(StartPolicy(windowed: false, safe: false))
		#expect(headless.startOptions(.safe) == StartOptions(openWindow: false, safe: true))
		let windowed = vm(StartPolicy(windowed: true, safe: false))
		#expect(windowed.startOptions(.safe) == StartOptions(openWindow: true, safe: true))
	}
}
