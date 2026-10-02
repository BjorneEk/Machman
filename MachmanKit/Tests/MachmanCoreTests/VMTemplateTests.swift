//
//  VMTemplateTests.swift
//  MachmanTests
//
//  createVM template semantics via the sync applyTemplate seam: blank seeds NOTHING
//  (no devices, no console port); default keeps the implied EFI set + the one console.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct VMTemplateTests {
	@Test @MainActor func blankSeedsNoDevicesAndNoConsole() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()

			let blank = try registry.create()
			try LocalMachman.applyTemplate(.blank, to: blank.config)
			#expect(blank.config.devices.isEmpty)
			#expect(blank.config.consolePorts.isEmpty)
			#expect(blank.config.uartPorts.isEmpty)

			// The contrast: default keeps the seeded console + implied devices.
			let dflt = try registry.create()
			try LocalMachman.applyTemplate(.default, to: dflt.config)
			#expect(dflt.config.consolePorts.count == 1)
			#expect(!dflt.config.devices.isEmpty)
		}
	}
}
