//
//  DiskReferenceTests.swift
//  MachmanTests
//
//  C5's guards: a file in one VM's folder that another VM uses is never pulled out from
//  under it — no delete or rename of that folder, no removal or rename of that disk. The
//  shape is the one Save as New VM leaves: the saved VM ("kept") owns data.raw, and the
//  original ("alpha") attaches it by reference.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct DiskReferenceTests {
	// Inside the redirect: kept owns data.raw; alpha (and optionally more) reference it.
	@MainActor
	private func makePair(referencing path: String? = nil) throws -> VMRegistry {
		try VMConfig.createNewVMDirectory(name: "kept")
		let kept = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
		try kept.addNewStorageDisk(name: "data", size: 4096)
		try VMConfig.createNewVMDirectory(name: "alpha")
		let alpha = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
		let target = path ?? machmanVMDir + "/kept/data.raw"
		try alpha.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: target)), safe: false))
		return VMRegistry()
	}

	private var raw: String { machmanVMDir + "/kept/data.raw" }

	@Test @MainActor func deleteRefusesWhileAnotherVMUsesAFileInIt() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))
			let alpha = try #require(registry.vm(named: "alpha"))

			let error = try #require(throws: MachmanError.self) { try registry.delete(kept) }
			#expect(error.code == .invalidState)
			#expect(error.message.contains("alpha uses data.raw from kept’s folder"))
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(registry.vm(named: "kept") === kept)

			// Removing alpha's reference only disconnects it; then kept goes.
			try registry.removeDisk(try #require(alpha.config.disks.first), from: alpha)
			#expect(FileManager.default.fileExists(atPath: raw))
			try registry.delete(kept)
			#expect(registry.vm(named: "kept") == nil)
		}
	}

	@Test @MainActor func renameRefusesLikewise() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))

			let error = try #require(throws: MachmanError.self) {
				try registry.rename(kept, to: "other")
			}
			#expect(error.code == .invalidState)
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/other"))
		}
	}

	@Test @MainActor func removingOrRenamingAUsedDiskIsRefused() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let kept = try #require(registry.vm(named: "kept"))
			let data = try #require(kept.config.disks.first)

			#expect(throws: MachmanError.self) { try registry.removeDisk(data, from: kept) }
			#expect(throws: MachmanError.self) {
				try registry.renameStorageDisk(id: data.id, of: kept, to: "renamed")
			}
			#expect(kept.config.disks == [data])
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(!FileManager.default.fileExists(atPath: machmanVMDir + "/kept/renamed.raw"))
		}
	}

	@Test @MainActor func theReferencingVMStaysFree() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			try registry.delete(try #require(registry.vm(named: "alpha")))
			#expect(FileManager.default.fileExists(atPath: raw))
			#expect(registry.vm(named: "kept") != nil)
		}
	}

	// "kept 2/…" is not inside "kept".
	@Test @MainActor func aSiblingFolderIsNotInside() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept 2")
			let registry = try makePair(referencing: machmanVMDir + "/kept 2/data.raw")
			try registry.delete(try #require(registry.vm(named: "kept")))
			#expect(registry.vm(named: "kept") == nil)
		}
	}

	// C5's start guard: no second writer of one disk file, whoever owns it.
	@Test @MainActor func sharedWritableDisksBlockASecondWriter() throws {
		try VMTestDir.withRedirectedDir {
			let registry = try makePair()
			let routing = RoutingMachman(registry: registry, daemonVersion: "test")
			routing.reserveStart("kept", mac: nil)   // kept is starting

			let error = try #require(throws: MachmanError.self) {
				try routing.checkSharedDisks(name: "alpha")
			}
			#expect(error.code == .invalidState)
			#expect(error.message
				== "kept is running with data.raw attached — stop kept before starting alpha")
			routing.releaseStart("kept")
			try routing.checkSharedDisks(name: "alpha")

			// A disabled shared disk and a shared iso attach nothing writable.
			let alpha = try #require(registry.vm(named: "alpha"))
			alpha.config.disks[0].enabled = false
			let iso = VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/shared.iso")))
			alpha.config.disks.append(iso)
			try #require(registry.vm(named: "kept")).config.disks.append(iso)
			routing.reserveStart("kept", mac: nil)
			try routing.checkSharedDisks(name: "alpha")
		}
	}

	// kept runs on a vmhost this daemon adopted: a stub answering on a scratch socket.
	@MainActor
	private func adoptRunning(
		_ name: String, into routing: RoutingMachman
	) async throws -> (MachmanServer, RemoteMachman) {
		let socketPath = TestEnvironment.socketPath("mm-disk")
		let stub = StubMachman()
		stub.vms[name] = StubMachman.makeInfo(name, state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(id: UUID(), name: name, socketPath: socketPath)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		return (server, client)
	}

	// vm.setEnabled edits a running VM's config but detaches nothing: a disk switched off
	// mid-run still blocks a second writer. What a start left unattached is known only for
	// a start this daemon made. Both VMs name one scratch image, so nothing below depends
	// on the redirected library.
	@Test @MainActor func aDiskSwitchedOffMidRunStillBlocksASecondWriter() async throws {
		let image = TestEnvironment.scratch + "shared-\(UUID().uuidString).img"
		let file = (image as NSString).lastPathComponent
		var registry: VMRegistry!
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "kept"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				try cfg.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
			}
			registry = VMRegistry()
			routing = RoutingMachman(registry: registry, daemonVersion: "test")
		}
		let (server, client) = try await adoptRunning("kept", into: routing)
		defer { server.stop() }
		// The daemon's copy carries the switch after a reload or its own restart.
		let kept = try #require(registry.vm(named: "kept"))
		kept.config.disks[0].enabled = false
		let host = try #require(routing.hostForTesting("kept"))

		// Adopted: what its start attached is unknown, so the switched-off entry counts.
		var error = try #require(throws: MachmanError.self) {
			try routing.checkSharedDisks(name: "alpha")
		}
		#expect(error.code == .invalidState)
		#expect(error.message
			== "kept may still have \(file) attached — stop kept before starting alpha")

		// A start this daemon made with the disk on attached it, whatever the flag says now.
		host.unattachedDisks = []
		error = try #require(throws: MachmanError.self) {
			try routing.checkSharedDisks(name: "alpha")
		}
		#expect(error.message
			== "kept is running with \(file) attached — stop kept before starting alpha")

		// One that left it off attached nothing.
		host.unattachedDisks = [(image as NSString).standardizingPath]
		try routing.checkSharedDisks(name: "alpha")
		await client.disconnect()
	}

	// The whole start refuses before it spawns anything, force or not. Both VMs name one
	// scratch image, so nothing below depends on the redirected library.
	@Test @MainActor func startRefusesASharedDiskEvenWithForce() async throws {
		let image = TestEnvironment.scratch + "shared-\(UUID().uuidString).img"
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "kept"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				try cfg.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		routing.locateVMHost = { nil }
		routing.reserveStart("kept", mac: nil)

		do {
			try await routing.start(vm: "alpha", options: StartOptions(force: true))
			Issue.record("expected a refusal")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("stop kept before starting alpha"))
		}
	}
}
