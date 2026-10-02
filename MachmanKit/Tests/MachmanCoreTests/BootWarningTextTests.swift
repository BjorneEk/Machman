//
//  BootWarningTextTests.swift
//  MachmanTests
//
//  W3 (E9): boot-time warnings reach the desktop as a toast and an Activity entry, which
//  name the VM ("<VM>: …"). The engine's warnings read raw ("skipping trackpad on X: it
//  needs a macOS guest") and named the VM again. Each is one sentence without the name now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct BootWarningTextTests {
	@Test @MainActor func warningsAreSentencesWithoutTheVMsName() throws {
		try VMTestDir.withRedirectedDir {
			let config = try VMRegistry().create().config
			config.boot = .efi
			config.devices = [GuestDevice(kind: .trackpad)]
			var future = GuestDevice(kind: .entropy)
			future.kind = "future"
			config.devices.append(future)
			let efiWarnings = config.resolvedDevices().warnings
			#expect(efiWarnings == [
				Samples.bootWarning,
				"A newer Machman added the device \u{201C}future\u{201D}, so it isn\u{2019}t "
					+ "attached.",
			])

			config.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 4 << 30))
			config.devices = [GuestDevice(kind: .clipboard)]
			let macWarnings = config.resolvedDevices().warnings
			#expect(macWarnings == [
				"Clipboard sharing isn\u{2019}t supported for macOS guests, so it isn\u{2019}t "
					+ "attached.",
			])
			for warning in efiWarnings + macWarnings {
				#expect(!warning.contains(config.name), "\(warning)")
			}
		}
	}

	@Test func aHeadlessStartSaysWhy() {
		#expect(VMRegistry.headlessStartWarning == "It has no display, so it started headless.")
	}
}
