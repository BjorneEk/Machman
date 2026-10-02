//
//  DeviceRefusalTextTests.swift
//  MachmanTests
//
//  W3: device and port refusals showed raw kinds ("X already has a guestSetup device", "no
//  audioInput device on X"). They name a device by the label the UI shows (moved to
//  MachmanAPI for this), in sentence case, the VM first.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct DeviceRefusalTextTests {
	private func refusal(_ body: () throws -> Void) -> String? {
		do {
			try body()
			return nil
		} catch let error as MachmanError {
			return error.message
		} catch {
			return "\(error)"
		}
	}

	@Test @MainActor func deviceRefusalsUseTheLabels() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let name = vm.config.name
			try? vm.config.addDevice(GuestDevice(kind: .guestSetup))
			#expect(refusal { try vm.config.addDevice(GuestDevice(kind: .guestSetup)) }
				== "\(name) already has the Guest Setup device")

			vm.config.devices.removeAll { $0.deviceKind == .audioInput }
			#expect(refusal { try vm.config.removeDevice(kind: .audioInput) }
				== "\(name) has no Mic device")

			#expect(refusal {
				try vm.config.setEnabled(
					disks: [:], mounts: [:], console: [:], uart: [:],
					devices: ["future-kind": true])
			} == "\(name) has no \u{201C}future-kind\u{201D} device")

			#expect(refusal {
				try vm.config.setEnabled(disks: [:], mounts: [:], console: ["7": true], uart: [:])
			} == "\(name) has no console port 7")
		}
	}

	@Test @MainActor func aMacGuestRefusesClipboardByItsLabel() throws {
		let config = try VMTestDir.withRedirectedDir { try VMRegistry().create().config }
		config.boot = .macOS(MacOSBoot(
			installState: .installed, minimumCPUCount: 2, minimumMemorySize: 4 << 30))
		#expect(refusal { try LocalMachman.validateDeviceKind(.clipboard, for: config) }
			== "Clipboard isn\u{2019}t supported for macOS guests")
		#expect(refusal { try LocalMachman.validateDeviceKind(.sshInstaller, for: config) }
			== "Replaced by Guest Setup in Machman 1.0.7")
	}
}
