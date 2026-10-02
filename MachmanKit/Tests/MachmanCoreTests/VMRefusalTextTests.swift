//
//  VMRefusalTextTests.swift
//  MachmanTests
//
//  W3: VM, run, copy and operation refusals read lowercase and raw ("no VM named 'x'",
//  "operation 'op-3' cannot be cancelled", "a vmhost owns x's socket…"), and the MAC-conflict
//  alert's message ran three sentences. They are sentence-case refusals now, one sentence,
//  in US spelling, with names quoted and no process jargon or ids.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct VMRefusalTextTests {
	@Test func plainRefusalsReadAsSentences() {
		#expect(MachmanError.notFound("x").message == "No VM named \u{201C}x\u{201D}")
		#expect(RoutingMachman.safeRunLabel == "Preparing a safe run")
	}

	@Test @MainActor func operationRefusalsShowNoIDs() {
		let center = OperationCenter(events: EventBus())
		let id = center.begin(kind: OperationInfo.Kind.importDisk, label: "Importing a.raw")
		#expect(refusal { try center.cancel(id: id) }
			== "This operation can\u{2019}t be canceled")
		#expect(refusal { try center.cancel(id: "op-404") } == "That operation already ended")
	}

	// The message of the desktop's and the agent's MAC-conflict alert: one sentence.
	@Test @MainActor func aMACConflictIsOneSentence() async throws {
		let mac = "aa:bb:cc:00:55:66"
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				cfg.macAddress = mac
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let socketPath = TestEnvironment.socketPath("mm-macsay")
		let stub = StubMachman()
		stub.vms["beta"] = StubMachman.makeInfo("beta", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "beta", socketPath: socketPath, macInUse: mac)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)

		let message = refusal {
			try routing.checkMACConflict(name: "alpha", mac: mac, options: StartOptions())
		}
		#expect(message == "alpha and the running VM \u{201C}beta\u{201D} share MAC address "
			+ "\(mac), so one of them would lose networking")
		// A refusal is one sentence with no trailing period: no sentence end at all.
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		#expect((message ?? "").matches(of: sentenceEnd).isEmpty)
		await client.disconnect()
	}

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
}
