//
//  SafeSaveHandOverTests.swift
//  MachmanTests
//
//  C5, the user's call (A-2e-1): Save as New VM moves the disks the run wrote directly — the
//  original's unsafe storage raws — into the saved VM's folder as its own, and the original
//  keeps them as references. Every failure before both configs are written rolls back
//  every rename, and no rollback ever parks a disk in the run root (deleted at run end).
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct SafeSaveHandOverTests {
	private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

	private func unsafe(_ name: String, size: UInt64 = 4096, enabled: Bool = true) -> VMDisk {
		var disk = VMDisk(kind: .storage(name, size), safe: false)
		disk.enabled = enabled
		return disk
	}

	private func contents(_ path: String) -> String? {
		FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
	}

	private func bytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

	@Test @MainActor func promotionMovesTheRunsDirectDisksAndBothConfigsSaySo() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [
				unsafe("data"), VMDisk(kind: .storage("system", 8192)),
			])
			defer { host.removeLibrary() }

			let promoted = try host.registry.promoteRestrictedVM(to: "kept")

			let kept = host.library + "/kept"
			#expect(contents(kept + "/data.raw") == "raw-data")
			#expect(contents(kept + "/system.raw") == "raw-system")   // the safe clone
			#expect(!FileManager.default.fileExists(atPath: host.originalDir + "/data.raw"))
			#expect(contents(host.originalDir + "/system.raw") == "raw-system")
			let saved = try SafeRunFixture.load(kept)
			#expect(saved.disks == [unsafe("data"), VMDisk(kind: .storage("system", 8192))])
			#expect(promoted.config.disks == saved.disks)
			#expect(try SafeRunFixture.load(host.originalDir).disks == [
				VMDisk(kind: .fromUrl(url(kept + "/data.raw")), safe: false),
				VMDisk(kind: .storage("system", 8192)),
			])
		}
	}

	// C19: the real shadow keeps a disabled disk disabled, so the run never attached or
	// wrote it. It stays the original's, and the saved VM keeps it as a disabled reference
	// there, which the cross-VM guards protect.
	@Test @MainActor func aDisabledDiskStaysWithTheOriginal() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [
				unsafe("data"), unsafe("scratch", enabled: false),
			])
			defer { host.removeLibrary() }
			let original = host.originalDir
			var reference = VMDisk(kind: .fromUrl(url(original + "/scratch.raw")), safe: false)
			reference.enabled = false
			let vm = try #require(host.registry.vm(named: "alpha"))
			#expect(vm.config.disks == [
				VMDisk(kind: .fromUrl(url(original + "/data.raw")), safe: false), reference,
			])

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			let kept = host.library + "/kept"
			#expect(!FileManager.default.fileExists(atPath: kept + "/scratch.raw"))
			#expect(contents(original + "/scratch.raw") == "raw-scratch")
			#expect(try SafeRunFixture.load(kept).disks == [unsafe("data"), reference])
			#expect(try SafeRunFixture.load(original).disks == [
				VMDisk(kind: .fromUrl(url(kept + "/data.raw")), safe: false),
				unsafe("scratch", enabled: false),
			])
			let daemon = VMRegistry()   // machmanVMDir is the library now
			let error = try #require(throws: MachmanError.self) {
				try daemon.delete(try #require(daemon.vm(named: "alpha")))
			}
			#expect(error.message.contains("kept uses scratch.raw from alpha's folder"))
		}
	}

	// The flags can change mid-run, the attachments can't: a disk switched off after the
	// start is still attached and written, so it moves; one switched on was never attached,
	// so it stays. Each entry keeps the flag it has now.
	@Test @MainActor func whatTheRunAttachedMovesWhateverItsFlagSaysNow() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [
				unsafe("data"), unsafe("scratch", enabled: false),
			])
			defer { host.removeLibrary() }
			let original = host.originalDir
			let vm = try #require(host.registry.vm(named: "alpha"))
			let ids = vm.config.disks.map(\.id)
			try vm.config.setEnabled(
				disks: [ids[0]: false, ids[1]: true], mounts: [:], console: [:], uart: [:])

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			let kept = host.library + "/kept"
			#expect(contents(kept + "/data.raw") == "raw-data")
			#expect(!FileManager.default.fileExists(atPath: kept + "/scratch.raw"))
			#expect(contents(original + "/scratch.raw") == "raw-scratch")
			#expect(try SafeRunFixture.load(kept).disks == [
				unsafe("data", enabled: false),
				VMDisk(kind: .fromUrl(url(original + "/scratch.raw")), safe: false),
			])
			#expect(try SafeRunFixture.load(original).disks == [
				VMDisk(kind: .fromUrl(url(kept + "/data.raw")), safe: false),
				unsafe("scratch", enabled: false),
			])
		}
	}

	// The guest keeps writing through descriptors it opened before the save.
	@Test @MainActor func aDescriptorOpenedBeforeTheSaveWritesTheMovedFile() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("data")])
			defer { host.removeLibrary() }
			let handle = try #require(FileHandle(forWritingAtPath: host.originalDir + "/data.raw"))

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			handle.seekToEndOfFile()
			handle.write(Data("+after".utf8))
			try handle.close()
			#expect(contents(host.library + "/kept/data.raw") == "raw-data+after")
		}
	}

	// A disk added to the running shadow already took "data" in the saved folder.
	@Test @MainActor func aTakenNameGetsTheFirstFreeSuffix() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("data")])
			defer { host.removeLibrary() }
			let vm = try #require(host.registry.vm(named: "alpha"))
			try vm.config.addNewStorageDisk(name: "data", size: 4096)

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			let kept = host.library + "/kept"
			#expect(contents(kept + "/data-2.raw") == "raw-data")
			#expect(FileManager.default.fileExists(atPath: kept + "/data.raw"))
			#expect(try SafeRunFixture.load(kept).disks.map(\.kind) == [
				.storage("data-2", 4096), .storage("data", 4096),
			])
			#expect(try SafeRunFixture.load(host.originalDir).disks.map(\.kind) == [
				.fromUrl(url(kept + "/data-2.raw")),
			])
		}
	}

	@Test @MainActor func externalImagesAndIsosNeverMove() throws {
		try VMTestDir.withRedirectedDir {
			let external = TestEnvironment.scratch + "ext-\(UUID().uuidString).img"
			try Data("ext".utf8).write(to: url(external))
			defer { try? FileManager.default.removeItem(atPath: external) }
			let iso = VMDisk(kind: .iso(url("/isos/x.iso")))
			let image = VMDisk(kind: .fromUrl(url(external)), safe: false)
			let host = try SafeRunFixture.make(disks: [iso, image])
			defer { host.removeLibrary() }
			let original = try #require(bytes(host.originalDir + "/config"))

			_ = try host.registry.promoteRestrictedVM(to: "kept")

			#expect(try SafeRunFixture.load(host.library + "/kept").disks == [iso, image])
			#expect(bytes(host.originalDir + "/config") == original)   // never rewritten
			#expect(contents(external) == "ext")
		}
	}

	// What the run looked like before a failed save, to compare against.
	@MainActor
	private struct Before {
		let shadowConfig: Data?
		let originalConfig: Data?
		let disks: [VMDisk]
		let mac: String?

		init(_ host: SafeRunFixture) throws {
			shadowConfig = FileManager.default.contents(atPath: host.shadowDir + "/config")
			originalConfig = FileManager.default.contents(atPath: host.originalDir + "/config")
			let vm = try #require(host.registry.vm(named: "alpha"))
			disks = vm.config.disks
			mac = vm.config.macAddress
		}

		func expectUnchanged(_ host: SafeRunFixture) throws {
			let fm = FileManager.default
			#expect(fm.contents(atPath: host.shadowDir + "/config") == shadowConfig)
			#expect(fm.contents(atPath: host.originalDir + "/config") == originalConfig)
			#expect(!fm.fileExists(atPath: host.library + "/kept"))
			#expect(host.registry.restrictedName == "alpha")
			#expect(machmanVMDir == host.runRoot)
			let vm = try #require(host.registry.vm(named: "alpha"))
			#expect(vm.config.name == "alpha")
			#expect(vm.config.disks == disks)
			#expect(vm.config.macAddress == mac)
		}
	}

	@Test @MainActor func aFailedDiskMoveRollsEverythingBack() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("a"), unsafe("b")])
			defer { host.removeLibrary() }
			let before = try Before(host)
			let rename = host.registry.renameExclusive
			host.registry.renameExclusive = { from, to in
				from.hasSuffix("/b.raw") ? EIO : rename(from, to)
			}

			let error = try #require(throws: MachmanError.self) {
				try host.registry.promoteRestrictedVM(to: "kept")
			}
			#expect(error.code == .ioFailure)
			try before.expectUnchanged(host)
			#expect(contents(host.originalDir + "/a.raw") == "raw-a")   // moved, then back
			#expect(contents(host.originalDir + "/b.raw") == "raw-b")

			// Nothing was spent: the same run saves once the moves work.
			host.registry.renameExclusive = rename
			_ = try host.registry.promoteRestrictedVM(to: "kept")
			#expect(contents(host.library + "/kept/b.raw") == "raw-b")
		}
	}

	// The original's config is written last; the folder turning read-only after the last
	// disk moved makes that write fail, and the way back opens it again.
	@Test @MainActor func aFailedOriginalConfigWriteRollsEverythingBack() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("a"), unsafe("b")])
			defer { host.removeLibrary() }
			let before = try Before(host)
			let rename = host.registry.renameExclusive
			let original = host.originalDir
			host.registry.renameExclusive = { from, to in
				if to.hasPrefix(original + "/") { chmod(original, 0o755) }   // moving back
				let code = rename(from, to)
				if from == original + "/b.raw" { chmod(original, 0o555) }
				return code
			}
			defer { chmod(original, 0o755) }

			#expect(throws: (any Error).self) { try host.registry.promoteRestrictedVM(to: "kept") }
			try before.expectUnchanged(host)
			#expect(contents(original + "/a.raw") == "raw-a")
			#expect(contents(original + "/b.raw") == "raw-b")
		}
	}

	// A disk that cannot go back must not ride the saved folder back into the run root, and
	// both configs then say where each disk is: kept owns the stranded one, alpha references
	// it there, and kept references the one that never moved, as the run did.
	@Test @MainActor func aDiskThatCannotGoBackKeepsTheSavedFolderInTheLibrary() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("a"), unsafe("b")])
			defer { host.removeLibrary() }
			let rename = host.registry.renameExclusive
			let original = host.originalDir
			host.registry.renameExclusive = { from, to in
				if from.hasSuffix("/b.raw") || to == original + "/a.raw" { return EIO }
				return rename(from, to)
			}

			#expect(throws: MachmanError.self) { try host.registry.promoteRestrictedVM(to: "kept") }
			let kept = host.library + "/kept"
			#expect(contents(kept + "/a.raw") == "raw-a")
			#expect(try SafeRunFixture.load(kept).disks.map(\.kind).contains(.storage("a", 4096)))
			#expect(!FileManager.default.fileExists(atPath: host.shadowDir))
			#expect(contents(original + "/b.raw") == "raw-b")
			#expect(try SafeRunFixture.load(kept).disks == [
				unsafe("a"), VMDisk(kind: .fromUrl(url(original + "/b.raw")), safe: false),
			])
			#expect(try SafeRunFixture.load(original).disks == [
				VMDisk(kind: .fromUrl(url(kept + "/a.raw")), safe: false), unsafe("b"),
			])
			// The daemon's view of the library: kept holds alpha's disk, so it stays put.
			machmanVMDir = host.library
			let daemon = VMRegistry()
			let error = try #require(throws: MachmanError.self) {
				try daemon.delete(try #require(daemon.vm(named: "kept")))
			}
			#expect(error.message.contains("alpha uses a.raw from kept's folder"))
		}
	}

	// The same when the saved folder's own way back fails: every disk went home, so kept
	// references them there and alpha's config stays as it was, and kept is a machine of
	// its own — no identifier of alpha's, a fresh macOS machine id.
	@Test @MainActor func aFolderThatCannotGoBackStaysAVMOfItsOwn() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("a"), unsafe("b")])
			defer { host.removeLibrary() }
			let vm = try #require(host.registry.vm(named: "alpha"))
			vm.config.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
			let shadow = host.shadowDir
			let sourceID = Data("alpha's machine".utf8)
			try sourceID.write(to: url(shadow + "/mac_machine_id"))
			try Data("vmid".utf8).write(to: url(shadow + "/vm_identifier"))
			let original = host.originalDir
			let originalConfig = bytes(original + "/config")
			let rename = host.registry.renameExclusive
			host.registry.renameExclusive = { from, to in
				if from.hasSuffix("/b.raw") || to == shadow { return EIO }
				return rename(from, to)
			}

			#expect(throws: MachmanError.self) { try host.registry.promoteRestrictedVM(to: "kept") }
			let kept = host.library + "/kept"
			#expect(!FileManager.default.fileExists(atPath: shadow))
			#expect(contents(original + "/a.raw") == "raw-a")   // moved, then back
			#expect(contents(original + "/b.raw") == "raw-b")
			#expect(try SafeRunFixture.load(kept).disks == [
				VMDisk(kind: .fromUrl(url(original + "/a.raw")), safe: false),
				VMDisk(kind: .fromUrl(url(original + "/b.raw")), safe: false),
			])
			#expect(bytes(original + "/config") == originalConfig)
			#expect(!FileManager.default.fileExists(atPath: kept + "/vm_identifier"))
			let minted = try #require(bytes(kept + "/mac_machine_id"))
			#expect(minted != sourceID)
			// The daemon's view of the library: kept uses alpha's disks, so alpha stays put.
			machmanVMDir = host.library
			let daemon = VMRegistry()
			let error = try #require(throws: MachmanError.self) {
				try daemon.delete(try #require(daemon.vm(named: "alpha")))
			}
			#expect(error.message.contains("kept uses a.raw from alpha's folder"))
		}
	}

	// Afterwards, in the daemon's registry: the saved VM is protected while the original
	// uses its disk; the original goes freely and leaves the disk with the saved VM.
	@Test @MainActor func theSavedVMIsProtectedAndTheOriginalIsFree() throws {
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(disks: [unsafe("data")])
			defer { host.removeLibrary() }
			_ = try host.registry.promoteRestrictedVM(to: "kept")
			let daemon = VMRegistry()   // machmanVMDir is the library now

			let kept = try #require(daemon.vm(named: "kept"))
			let error = try #require(throws: MachmanError.self) { try daemon.delete(kept) }
			#expect(error.message.contains("alpha uses data.raw from kept's folder"))
			try daemon.delete(try #require(daemon.vm(named: "alpha")))
			#expect(contents(host.library + "/kept/data.raw") == "raw-data")
			try daemon.delete(kept)
		}
	}

	// The daemon's half: after the vmhost's reply it re-reads the original, whose config the
	// vmhost rewrote during the run (the daemon's copy is from before it).
	@Test @MainActor func theDaemonListsTheOriginalWithItsNewReference() async throws {
		var registry: VMRegistry!
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.addNewStorageDisk(name: "data", size: 4096)
			registry = VMRegistry()
			routing = RoutingMachman(registry: registry, daemonVersion: "test")
		}
		let socketPath = TestEnvironment.scratch
			+ "mm-hand-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		let host = try #require(routing.hostForTesting("alpha"))

		try VMTestDir.withRedirectedDir {
			// What the vmhost left behind: kept owns data.raw, alpha references it.
			try VMConfig.createNewVMDirectory(name: "kept")
			let kept = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			try kept.addNewStorageDisk(name: "data", size: 4096)
			try VMConfig.createNewVMDirectory(name: "alpha")
			let alpha = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			let moved = url(machmanVMDir + "/kept/data.raw")
			try alpha.addDisk(disk: VMDisk(kind: .fromUrl(moved), safe: false))

			_ = routing.finishSafeSave(
				host, from: "alpha", to: "kept",
				reply: StubMachman.makeInfo("kept", state: .running))

			#expect(registry.vm(named: "alpha")?.config.disks.map(\.kind) == [.fromUrl(moved)])
			#expect(registry.vm(named: "kept") != nil)
		}
		#expect(routing.hostedNames == ["kept"])
		await client.disconnect()
	}

	// The run switched data off after its start, so data stayed attached and moved with the
	// save. kept, adopted from disk with the flag off, still blocks alpha from writing it.
	@Test @MainActor func aSavedRunStillBlocksTheDiskItSwitchedOff() async throws {
		var registry: VMRegistry!
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.addNewStorageDisk(name: "data", size: 4096)
			registry = VMRegistry()
			routing = RoutingMachman(registry: registry, daemonVersion: "test")
		}
		let socketPath = TestEnvironment.scratch
			+ "mm-off-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		let host = routing.adopt(identity: identity, client: client)
		host.unattachedDisks = []   // as the safe start recorded it: data was on

		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept")
			let kept = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			try kept.addNewStorageDisk(name: "data", size: 4096)
			try kept.setEnabled(
				disks: [kept.disks[0].id: false], mounts: [:], console: [:], uart: [:])
			try VMConfig.createNewVMDirectory(name: "alpha")
			let alpha = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			let moved = url(machmanVMDir + "/kept/data.raw")
			try alpha.addDisk(disk: VMDisk(kind: .fromUrl(moved), safe: false))

			_ = routing.finishSafeSave(
				host, from: "alpha", to: "kept",
				reply: StubMachman.makeInfo("kept", state: .running))

			#expect(registry.vm(named: "kept")?.config.disks.map(\.enabled) == [false])
			let error = try #require(throws: MachmanError.self) {
				try routing.checkSharedDisks(name: "alpha")
			}
			#expect(error.message
				== "kept is running with data.raw attached — stop kept before starting alpha")
		}
		await client.disconnect()
	}

	// A save the vmhost could not undo left kept in the library holding alpha's disk, and
	// rewrote both configs. The daemon lists them at once, not after its next start.
	@Test @MainActor func theDaemonListsAHalfSavedVMAtOnce() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let alpha = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try alpha.addNewStorageDisk(name: "data", size: 4096)
			let registry = VMRegistry()
			let routing = RoutingMachman(registry: registry, daemonVersion: "test")
			let before = FileManager.default.fileExists(atPath: machmanVMDir + "/kept/config")

			try VMConfig.createNewVMDirectory(name: "kept")
			let kept = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			try kept.addNewStorageDisk(name: "data", size: 4096)
			let moved = url(machmanVMDir + "/kept/data.raw")
			alpha.disks = [VMDisk(kind: .fromUrl(moved))]
			try alpha.saveVMConfig()
			routing.listHalfSavedVM(
				"kept", from: "alpha", library: machmanVMDir, existedBefore: before)

			#expect(registry.vm(named: "kept") != nil)
			#expect(registry.vm(named: "alpha")?.config.disks.map(\.kind) == [.fromUrl(moved)])

			// A folder that was there before the save is not the save's to list.
			try VMConfig.createNewVMDirectory(name: "stray")
			_ = try VMConfig(name: "stray", memorySize: 2048, cpuCount: 2)
			routing.listHalfSavedVM(
				"stray", from: "alpha", library: machmanVMDir, existedBefore: true)
			#expect(registry.vm(named: "stray") == nil)
		}
	}

	// alpha's safe run on a stub vmhost this daemon adopted. Its save goes to `library`,
	// given explicitly so no parallel test's redirect can move it under the call.
	@MainActor
	private func adoptSafeRun(
		into routing: RoutingMachman, library: String, stub: StubMachman
	) async throws -> (MachmanServer, RemoteMachman) {
		let socketPath = TestEnvironment.scratch
			+ "mm-half-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		var running = StubMachman.makeInfo("alpha", state: .running)
		running.safeRun = true
		stub.vms["alpha"] = running
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: "/nonexistent", library: library)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		return (server, client)
	}

	// The real path: the vmhost's refusal reaches the caller, and with no saved folder left
	// behind nothing new is listed and the run stays the original's.
	@Test @MainActor func aFailedSaveRethrowsAndListsNothingNew() async throws {
		let library = TestEnvironment.scratch + "lib-\(UUID().uuidString)"
		var registry: VMRegistry!
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			_ = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			registry = VMRegistry()
			routing = RoutingMachman(registry: registry, daemonVersion: "test")
		}
		let stub = StubMachman()
		stub.fail("safeSave", with: MachmanError(code: .ioFailure, message: "saving half-saved"))
		let (server, client) = try await adoptSafeRun(into: routing, library: library, stub: stub)
		defer { server.stop() }

		let error = await #expect(throws: MachmanError.self) {
			_ = try await routing.safeSave(vm: "alpha", to: "half-saved")
		}
		#expect(error?.code == .ioFailure)
		#expect(registry.vm(named: "half-saved") == nil)
		#expect(routing.hostedNames == ["alpha"])
		await client.disconnect()
	}

	// The real path when the vmhost could neither finish nor undo the save: kept stays in
	// the library holding alpha's disk, and alpha's config references it there. The daemon
	// lists both as they are now before it passes the failure on.
	@Test @MainActor func aSaveThatFailsHalfWayListsWhatItLeft() async throws {
		let library = TestEnvironment.scratch + "lib-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: library) }
		var registry: VMRegistry!
		var routing: RoutingMachman!
		var original: VMConfig!
		var saved: VMConfig!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			original = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try original.addNewStorageDisk(name: "data", size: 4096)
			registry = VMRegistry()
			routing = RoutingMachman(registry: registry, daemonVersion: "test")
			try VMConfig.createNewVMDirectory(name: "kept")
			saved = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			try saved.addNewStorageDisk(name: "data", size: 4096)
		}
		// The library before the save: alpha owns data.raw.
		let fm = FileManager.default
		try fm.createDirectory(atPath: library + "/alpha", withIntermediateDirectories: true)
		try SafeRunFixture.write(original, to: library + "/alpha")
		let moved = url(library + "/kept/data.raw")
		let alpha: VMConfig = original, kept: VMConfig = saved
		alpha.disks = [VMDisk(kind: .fromUrl(moved), safe: false)]
		let stub = StubMachman()
		stub.onSafeSave = { _, newName in
			// What the vmhost leaves: kept owns data.raw, alpha references it there.
			try? fm.createDirectory(
				atPath: library + "/" + newName, withIntermediateDirectories: true)
			try? SafeRunFixture.write(kept, to: library + "/" + newName)
			try? SafeRunFixture.write(alpha, to: library + "/alpha")
		}
		stub.fail("safeSave", with: MachmanError(code: .ioFailure, message: "saving kept"))
		let (server, client) = try await adoptSafeRun(into: routing, library: library, stub: stub)
		defer { server.stop() }

		let error = await #expect(throws: MachmanError.self) {
			_ = try await routing.safeSave(vm: "alpha", to: "kept")
		}
		#expect(error?.code == .ioFailure)
		#expect(registry.vm(named: "kept")?.config.disks.map(\.kind) == [.storage("data", 4096)])
		#expect(registry.vm(named: "alpha")?.config.disks.map(\.kind) == [.fromUrl(moved)])
		#expect(routing.hostedNames == ["alpha"])
		await client.disconnect()
	}
}

// The one warning at the save, so the first sign of the hand-over is not a later refusal.
struct SafeSaveHandOverWarningTests {
	@Test func theWarningNamesTheMovedFiles() {
		let one = [DirectDiskMove(storage: "data", size: 0, target: "data")]
		#expect(DirectDiskMove.handOverWarning(one, original: "alpha", saved: "kept")
			== "alpha's disk data.raw now lives in kept's folder; kept can't be deleted while "
				+ "alpha uses it")
		let two = one + [DirectDiskMove(storage: "b", size: 0, target: "b-2")]
		#expect(DirectDiskMove.handOverWarning(two, original: "alpha", saved: "kept")
			== "alpha's disks data.raw, b-2.raw now live in kept's folder; kept can't be "
				+ "deleted while alpha uses them")
		#expect(DirectDiskMove.handOverWarning([], original: "alpha", saved: "kept") == nil)
	}

	@Test @MainActor func theSaveRaisesItOnce() async throws {
		var registry: VMRegistry!
		var stream: AsyncStream<VMEvent>!
		try VMTestDir.withRedirectedDir {
			let host = try SafeRunFixture.make(
				disks: [VMDisk(kind: .storage("data", 4096), safe: false)])
			defer { host.removeLibrary() }
			registry = host.registry
			stream = registry.events.stream()
			_ = try registry.promoteRestrictedVM(to: "kept")
			registry.events.emit(.log(vm: nil, level: .message, message: "end"))
		}
		var warnings: [String] = []
		for await event in stream {
			guard case .log(_, let level, let message) = event else { continue }
			if message == "end" { break }
			if level == .warning { warnings.append(message) }
		}
		#expect(warnings == [
			"alpha's disk data.raw now lives in kept's folder; kept can't be deleted while "
				+ "alpha uses it",
		])
	}
}
