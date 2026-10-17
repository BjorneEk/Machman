//
//  VMHostHelloTests.swift
//  MachmanCoreTests
//
//  PR21 (E11): a vmhost's hello says whom it serves — its pid, the VM by its current name,
//  its data folder, the VM's folder where that is now, and whether it serves a safe run's
//  shadow — so the agent can place a vmhost it finds on a socket no VM accounts for, and
//  never adopt one as a VM whose folder it doesn't serve. The agent's own hello says none.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct VMHostHelloTests {
	@Test("E11: a vmhost's hello names its pid, VM, data folder and its VM folder where it is now")
	@MainActor func aVMHostsHelloSaysWhomItServes() async throws {
		let fm = FileManager.default
		let library = TestEnvironment.scratch + "hello-\(UUID().uuidString)"
		try fm.createDirectory(atPath: library + "/alpha", withIntermediateDirectories: true)
		defer { try? fm.removeItem(atPath: library) }
		// F_GETPATH answers the real path (/private/tmp…).
		let real = try #require(realpath(library, nil).map { pointer in
			defer { free(pointer) }
			return String(cString: pointer)
		})
		let folder = VMFolderPath(library + "/alpha")
		let socketPath = TestEnvironment.socketPath("mm-hello")
		let server = MachmanServer(
			api: StubMachman(), socketPath: socketPath, daemonVersion: "test-vmhost")
		server.helloHost = {
			RPCResults.Hello.Host(
				pid: getpid(), vm: "alpha", dataDir: library, vmDir: folder.current,
				shadow: false)
		}
		try startServing(server)
		defer { server.stop() }

		let first = try await RemoteMachman(socketPath: socketPath, clientName: "e11")
		#expect(first.hello.host == RPCResults.Hello.Host(
			pid: getpid(), vm: "alpha", dataDir: library, vmDir: real + "/alpha",
			shadow: false))
		await first.disconnect()

		// Renamed in Finder under the running VM: the folder's path follows it.
		try fm.moveItem(atPath: library + "/alpha", toPath: library + "/beta")
		let second = try await RemoteMachman(socketPath: socketPath, clientName: "e11")
		#expect(second.hello.host?.vmDir == real + "/beta")
		await second.disconnect()

		// Deleted: there is no folder to name.
		try fm.removeItem(atPath: library + "/beta")
		#expect(folder.current == nil)

		// The agent's hello says nothing of the kind.
		let agentSocket = TestEnvironment.socketPath("mm-hello-agent")
		let agent = MachmanServer(
			api: StubMachman(), socketPath: agentSocket, daemonVersion: "test")
		try startServing(agent)
		defer { agent.stop() }
		let client = try await RemoteMachman(socketPath: agentSocket, clientName: "e11")
		#expect(client.hello.host == nil)
		await client.disconnect()
	}

	// What VMHostBootstrap serves: the VM's current name and data folder, and a safe run's
	// shadow until it is saved as a new VM (the name changes then).
	@Test("E11: a vmhost's hello follows its VM's name and says whether it serves a shadow")
	@MainActor func theHelloFollowsTheVMsNameAndShadow() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			let registry = VMRegistry(only: "alpha")
			let folder = VMFolderPath(machmanVMDir + "/alpha")
			let shadow = VMHostBootstrap.helloHost(
				registry: registry, vmName: "alpha", folder: folder, isShadow: true)()
			#expect(shadow?.vm == "alpha")
			#expect(shadow?.dataDir == machmanVMDir)
			#expect(shadow?.pid == getpid())
			#expect(shadow?.shadow == true)
			let plain = VMHostBootstrap.helloHost(
				registry: registry, vmName: "alpha", folder: folder, isShadow: false)()
			#expect(plain?.shadow == false)
		}
	}
}
