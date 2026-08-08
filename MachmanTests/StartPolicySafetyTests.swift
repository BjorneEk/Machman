//
//  StartPolicySafetyTests.swift
//  MachmanTests
//
//  Persistence behavior of the start-policy and safety setters.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct StartPolicySafetyTests {
	@Test @MainActor func setStartPolicyPersistsAcrossLoad() throws {
		try VMTestDir.withRedirectedDir {
			let name = "policy-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)

			let policy = StartPolicy(windowed: false, safe: false, autostart: true)
			try cfg.setStartPolicy(policy)
			#expect(try VMConfig.load(name: name).startPolicy == policy)
		}
	}
}
