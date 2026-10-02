//
//  OperationFailureTextTests.swift
//  MachmanTests
//
//  E28: a failed operation's card (and its Activity entry) showed the error interpolated
//  whole — importing a qcow2 image read "MachmanError(code: MachmanAPI.MachmanError.Code.
//  invalidArgument, message: …)". Operation failures carry the error's own sentence now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct OperationFailureTextTests {
	@Test @MainActor func aFailedImportCarriesTheRefusalItself() async throws {
		var api: LocalMachman!
		var name = ""
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			name = try registry.create().config.name
			api = LocalMachman(registry: registry)
		}
		let qcow = TestEnvironment.scratch + "qcow-\(UUID().uuidString).qcow2"
		try Data([0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3] + [UInt8](repeating: 0, count: 504))
			.write(to: URL(fileURLWithPath: qcow))
		defer { try? FileManager.default.removeItem(atPath: qcow) }

		// The sniff refuses before anything touches the VM's folder.
		var thrown: MachmanError?
		do {
			_ = try await api.importDisk(vm: name, path: qcow)
		} catch let error as MachmanError {
			thrown = error
		}
		let refusal = try #require(thrown)
		let op = try #require(
			try await api.operations().first { $0.kind == OperationInfo.Kind.importDisk })
		#expect(op.state == OperationInfo.State.failed)
		#expect(op.message == refusal.message)
		#expect(op.message?.contains("MachmanError(") == false)
	}

	@Test func aCriticalEngineErrorReadsItsSentence() {
		let error: Error = VirtualMachineError.critical("Kernel image not found: /k/vmlinuz")
		#expect(error.localizedDescription == "Kernel image not found: /k/vmlinuz")
		#expect(MachmanError.userMessage(for: error) == "Kernel image not found: /k/vmlinuz")
	}
}
