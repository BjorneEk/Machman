//
//  SSHRefusalTextTests.swift
//  MachmanTests
//
//  W3: the SSH refusals still sent users to "the SSH Setup script" (Guest Setup since 1.0.7),
//  and the router quoted an alias with straight quotes where the desktop's own field
//  problem uses curly ones.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct SSHRefusalTextTests {
	private func refusal(_ body: () async throws -> Void) async -> String? {
		do {
			try await body()
			return nil
		} catch let error as MachmanError {
			return error.message
		} catch {
			return "\(error)"
		}
	}

	@Test @MainActor func approvingWithoutAKeyNamesGuestSetup() async throws {
		let config = try VMTestDir.withRedirectedDir { try VMRegistry().create().config }
		let message = await refusal {
			try config.setSSH(integrationEnabled: nil, reverseApproved: true, alias: nil)
		}
		#expect(message == "No guest key reported yet \u{2014} run Guest Setup in "
			+ "\(config.name) with --two-way first")
	}

	@Test @MainActor func aTakenAliasMatchesTheDesktopsProblem() async throws {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let message = await refusal {
			_ = try await routing.setSSH(
				vm: "alpha", integrationEnabled: nil, reverseApproved: nil,
				alias: "beta.machman")
		}
		#expect(message == "beta already answers to \u{201C}beta.machman\u{201D}")
	}
}
