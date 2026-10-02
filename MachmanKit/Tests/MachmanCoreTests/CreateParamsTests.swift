//
//  CreateParamsTests.swift
//  MachmanTests
//
//  A8: vm.create's optional params are read strictly. Absent, null or {} still mean the
//  default template, but a malformed params object answers invalid params and an unknown
//  template name is refused — the server used to swallow a bad decode as "no template" and
//  create a VM with the default set. Over a real socket, with raw calls (RemoteMachman only
//  ever sends a typed template).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct CreateParamsTests {
	private struct NumberTemplate: Codable { var template: Int }
	private struct NamedTemplate: Codable { var template: String }

	@MainActor
	private func serve() throws -> (StubMachman, MachmanServer, RPCConnection) {
		let socketPath = TestEnvironment.scratch
			+ "mm-create-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		return (stub, server, try RPCConnection(socketPath: socketPath))
	}

	@Test @MainActor func aNonStringTemplateIsRefused() async throws {
		let (stub, server, connection) = try serve()
		defer { server.stop() }
		do {
			_ = try await connection.call(
				.vmCreate, NumberTemplate(template: 5), expecting: VMInfo.self)
			Issue.record("a numeric template must not create a VM")
		} catch let error as MachmanError {
			#expect(error.message.hasPrefix("invalid params"))
		}
		#expect(!stub.calls.contains("createVM"))
		#expect(stub.vms.isEmpty)
	}

	@Test @MainActor func anUnknownTemplateIsRefused() async throws {
		let (stub, server, connection) = try serve()
		defer { server.stop() }
		do {
			_ = try await connection.call(
				.vmCreate, NamedTemplate(template: "bogus"), expecting: VMInfo.self)
			Issue.record("an unknown template must not create a VM")
		} catch let error as MachmanError {
			#expect(error.code == .invalidArgument)
			#expect(error.message == "unknown VM template 'bogus' — use blank, default or mac")
		}
		#expect(!stub.calls.contains("createVM"))
		#expect(stub.vms.isEmpty)
	}

	@Test @MainActor func absentParamsMeanTheDefault() async throws {
		let (stub, server, connection) = try serve()
		defer { server.stop() }
		_ = try await connection.call(.vmCreate, RPCEmpty?.none, expecting: VMInfo.self)
		#expect(stub.lastCreateTemplate == nil)
		_ = try await connection.call(.vmCreate, RPCEmpty(), expecting: VMInfo.self)
		#expect(stub.lastCreateTemplate == nil)
		#expect(stub.vms.count == 2)
	}

	@Test @MainActor func eachTemplateArrivesTyped() async throws {
		let (stub, server, connection) = try serve()
		defer { server.stop() }
		for template in VMTemplate.allCases {
			_ = try await connection.call(
				.vmCreate, NamedTemplate(template: template.rawValue), expecting: VMInfo.self)
			#expect(stub.lastCreateTemplate == template)
		}
	}
}
