//
//  CopyMountsLoopbackTests.swift
//  MachmanTests
//
//  vm.copy's mount choice end to end: RemoteMachman → socket → MachmanServer → engine
//  (a StubMachman), the LoopbackTests rig.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct CopyMountsLoopbackTests {
	@Test @MainActor func theMountChoiceCrossesTheWire() async throws {
		let socketPath = TestEnvironment.socketPath("mm-cmount")
		let stub = StubMachman()
		var debian = StubMachman.makeInfo("Debian")
		debian.mounts = [
			MountInfo(id: "m-keep", path: "/x/src", tag: "src"),
			MountInfo(id: "m-drop", path: "/x/notes", tag: "notes"),
		]
		stub.vms["Debian"] = debian
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "copy-mounts")

		let copy = try await client.copyVM(
			vm: "Debian", newName: "Debian copy", diskIDs: nil, mountIDs: ["m-keep"],
			regenerateMAC: true)
		#expect(copy.mounts.map(\.id) == ["m-keep"])
		#expect(stub.copies.last?.mountIDs == ["m-keep"])

		// The pre-choice call shape still means "every mount".
		_ = try await client.copyVM(
			vm: "Debian", newName: "Debian twin", diskIDs: nil, regenerateMAC: true)
		#expect(stub.copies.last?.mountIDs == nil)
		await client.disconnect()
	}
}
