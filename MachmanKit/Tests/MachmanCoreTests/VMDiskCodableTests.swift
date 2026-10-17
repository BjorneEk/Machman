//
//  VMDiskCodableTests.swift
//  MachmanTests
//
//  Persistence-shape tests for the disk and mount config types. Uses plain JSONEncoder/Decoder
//  (the persistence coders), not MachmanWire — these types never cross the wire directly.
//

import Foundation
import Testing
import MachmanAPI
@testable import MachmanCore

struct VMDiskCodableTests {
	@Test func mountPointIDSurvivesRoundTrip() throws {
		let mount = HostMountPoint(path: "/Users/x/share", tag: "share")
		let data = try JSONEncoder().encode(mount)
		let back = try JSONDecoder().decode(HostMountPoint.self, from: data)
		#expect(back.id == mount.id)
		#expect(back.path == mount.path)
		#expect(back.tag == mount.tag)
	}

	@Test func legacyMountWithoutIDDecodesWithMintedID() throws {
		let legacy = Data(#"{"path":"/Users/x/share","tag":"share"}"#.utf8)
		let a = try JSONDecoder().decode(HostMountPoint.self, from: legacy)
		let b = try JSONDecoder().decode(HostMountPoint.self, from: legacy)
		#expect(a.path == "/Users/x/share")
		#expect(a.tag == "share")
		#expect(a.id != b.id)
		#expect(a.safe == true)
	}

	@Test func legacyDiskDecodesSafeTrue() throws {
		// The exact shape live configs carry: synthesized enum coding, positional keys.
		let legacy = Data(#"{"storage":{"_0":"disk","_1":0}}"#.utf8)
		let disk = try JSONDecoder().decode(VMDisk.self, from: legacy)
		#expect(disk.kind == .storage("disk", 0))
		#expect(disk.safe == true)
		#expect(disk.id == "storage:disk")
	}

	@Test func newDiskShapeRoundTrips() throws {
		let disk = VMDisk(kind: .fromUrl(URL(fileURLWithPath: "/tmp/t.raw")), safe: false)
		let data = try JSONEncoder().encode(disk)
		#expect(String(decoding: data, as: UTF8.self).contains(#""kind""#))
		let back = try JSONDecoder().decode(VMDisk.self, from: data)
		#expect(back == disk)
	}

	@Test func fullLegacyConfigLoadsWithNameAuthorityAndMACMigration() throws {
		try VMTestDir.withRedirectedDir {
			let dir = "\(machmanVMDir)/legacy-load"
			try FileManager.default.createDirectory(
				atPath: dir, withIntermediateDirectories: true)
			// A pre-refactor config: stale name in the file, legacy disk shape, no macAddress,
			// mounts without ids.
			let legacy = """
			{"name":"stale-name-in-file","memorySize":2048,"cpuCount":2,
			"created":100000,
			"disks":[{"storage":{"_0":"disk","_1":0}}],
			"mountPoints":[{"path":"/Users/x/share","tag":"share"}]}
			"""
			try Data(legacy.utf8).write(to: URL(fileURLWithPath: "\(dir)/config"))

			let config = try VMConfig.load(name: "legacy-load")
			#expect(config.name == "legacy-load")            // directory name is authoritative
			#expect(config.disks.first?.safe == true)
			#expect(config.mountPoints.first?.safe == true)
			#expect(config.macAddress != nil)                // minted on first load…
			let again = try VMConfig.load(name: "legacy-load")
			#expect(again.macAddress == config.macAddress)   // …and persisted
		}
	}

	// D38 (review 4): D26 made a newer boot mode survive a load, but a disk entry of a kind
	// this build can't decode (a newer Machman's) still failed the whole config: the VM
	// vanished from every client with one passive log line, and its name looked free.
	@Test("D38: a config with a disk kind this build doesn't know still loads, keeping it")
	func aNewerDiskKindStillLoads() throws {
		try VMTestDir.withRedirectedDir {
			let dir = "\(machmanVMDir)/newer-disk"
			try FileManager.default.createDirectory(
				atPath: dir, withIntermediateDirectories: true)
			let config = """
			{"name":"newer-disk","memorySize":2048,"cpuCount":2,"created":100000,
			"macAddress":"aa:bb:cc:dd:ee:02",
			"disks":[{"kind":{"storage":{"_0":"system","_1":0}}},
			{"kind":{"nvme":{"_0":"fast","_1":512}},"safe":false}]}
			"""
			try Data(config.utf8).write(to: URL(fileURLWithPath: "\(dir)/config"))
			let loaded = try? VMConfig.load(name: "newer-disk")
			#expect(loaded != nil)
			// The entry is kept for the Machman that wrote it.
			#expect(loaded?.disks.count == 2)
		}
	}

	private static let newerDiskConfig = """
		{"name":"newer-disk","memorySize":2048,"cpuCount":2,"created":100000,
		"macAddress":"aa:bb:cc:dd:ee:02",
		"disks":[{"kind":{"storage":{"_0":"system","_1":0}}},
		{"kind":{"nvme":{"_0":"fast","_1":512}},"safe":false}]}
		"""

	// D38 (review 4): the entry a newer Machman wrote lists by what it is, refuses to start
	// while it is enabled — a disabled disk isn't attached, so the VM then starts without it —
	// and every save writes it back as that Machman wrote it.
	@Test("D38: a newer disk kind lists, refuses to start while enabled and saves back as read")
	@MainActor func aNewerDiskKindIsKeptAsRead() throws {
		try VMTestDir.withRedirectedDir {
			let dir = "\(machmanVMDir)/newer-disk"
			try FileManager.default.createDirectory(
				atPath: dir, withIntermediateDirectories: true)
			let file = URL(fileURLWithPath: "\(dir)/config")
			try Data(Self.newerDiskConfig.utf8).write(to: file)
			let registry = VMRegistry()
			let vm = try #require(registry.vm(named: "newer-disk"))
			let listed = LocalMachman(registry: registry).info(for: vm).disks
			#expect(listed.map(\.type) == [.storage, .unknown])
			#expect(listed.last?.name == VMDisk.newerKindName)
			#expect(listed.last?.path == nil && listed.last?.safe == false)
			let refused = try #require(throws: MachmanError.self) {
				try vm.config.requireStartable()
			}
			#expect(refused.code == .invalidState)

			try vm.config.setCPUCount(1)
			func newerEntry(_ data: Data) throws -> NSDictionary? {
				let config = try JSONSerialization.jsonObject(with: data) as? NSDictionary
				return (config?["disks"] as? NSArray)?.lastObject as? NSDictionary
			}
			let written = try newerEntry(Data(contentsOf: file))
			#expect(written != nil)
			#expect(written == (try newerEntry(Data(Self.newerDiskConfig.utf8))))

			let id = try #require(listed.last?.id)
			try vm.config.setEnabled(disks: [id: false], mounts: [:], console: [:], uart: [:])
			try vm.config.requireStartable()
			let reloaded = try VMConfig.load(name: "newer-disk")
			#expect(reloaded.disks.last?.enabled == false)
			#expect(reloaded.disks.last?.id == id)
		}
	}

	@Test func mountKindDefaultsPinsAndPreservesUnknowns() throws {
		// Legacy mounts (no kind) decode as virtiofs.
		let legacy = try JSONDecoder().decode(HostMountPoint.self,
			from: Data(#"{"path":"/Users/x/share","tag":"share"}"#.utf8))
		#expect(legacy.kind == MountKind.virtiofs)
		// A chosen kind survives the round trip.
		let sshfs = HostMountPoint(path: "/Users/x/docs", tag: "docs", kind: MountKind.sshfs)
		let back = try JSONDecoder().decode(
			HostMountPoint.self, from: try JSONEncoder().encode(sshfs))
		#expect(back.kind == MountKind.sshfs)
		// A future kind written by a newer daemon survives this one's load/save verbatim.
		let future = try JSONDecoder().decode(HostMountPoint.self,
			from: Data(#"{"path":"/x","tag":"t","kind":"teleport"}"#.utf8))
		let rewritten = String(
			decoding: try JSONEncoder().encode(future), as: UTF8.self)
		#expect(rewritten.contains(#""kind":"teleport""#))
	}

	@Test func legacyInstallerDevicesMigrateToOneGuestSetup() throws {
		try VMTestDir.withRedirectedDir {
			let dir = "\(machmanVMDir)/installer-migrate"
			try FileManager.default.createDirectory(
				atPath: dir, withIntermediateDirectories: true)
			// A 1.0.6 config: both installers attached, the console one disabled.
			let legacy = """
			{"name":"installer-migrate","memorySize":2048,"cpuCount":2,
			"created":100000,"macAddress":"aa:bb:cc:dd:ee:ff",
			"devices":[{"kind":"consoleLoginInstaller","enabled":false},
			{"kind":"network"},{"kind":"sshInstaller","enabled":true}]}
			"""
			try Data(legacy.utf8).write(to: URL(fileURLWithPath: "\(dir)/config"))

			let config = try VMConfig.load(name: "installer-migrate")
			let kinds = config.devices.map(\.kind)
			#expect(kinds == ["guestSetup", "network"])   // first legacy position, deduped
			#expect(config.devices.first?.enabled == true)   // enabled if either was
			// The migration persisted: the file no longer carries the legacy kinds.
			let bytes = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/config"))
			let text = String(decoding: bytes, as: UTF8.self)
			#expect(!text.contains("sshInstaller"))
			#expect(!text.contains("consoleLoginInstaller"))
			#expect(text.contains("guestSetup"))
		}
	}

	@Test func setupConfigPersistsConditionally() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "setup-state")
			let config = try VMConfig(name: "setup-state", memorySize: 2048, cpuCount: 2)
			// Absent until first used: a fresh config carries no setup key at all.
			var bytes = try Data(contentsOf: URL(fileURLWithPath: config.configPath()))
			#expect(!String(decoding: bytes, as: UTF8.self).contains(#""setup""#))

			var state = GuestSetupConfig()
			state.installed = true
			state.guestOS = "debian"
			state.guestInit = "systemd"
			state.scriptVersion = 3
			state.errors = [GuestSetupError(step: "sshd", message: "could not enable")]
			state.features = [GuestFeatureInfo(
				id: GuestFeature.console, available: true, configured: true,
				detail: "hvc0")]
			state.consoles = [GuestConsoleInfo(device: "hvc0", login: "active")]
			state.automounts = [GuestAutomountInfo(
				kind: MountKind.virtiofs, target: "host-share",
				path: "/mnt/machman/share")]
			state.reinstallRequested = true
			config.setup = state
			try config.saveVMConfig()

			let back = try VMConfig.load(name: "setup-state")
			#expect(back.setup == state)
			#expect(back.setup?.reinstallRequested == true)

			// THE serve rule: fresh guests always serve; installed guests only on request.
			#expect(back.servesSetupPayload)          // installed + requested
			back.setup?.reinstallRequested = nil
			#expect(!back.servesSetupPayload)         // installed, no request
			back.setup = nil
			#expect(back.servesSetupPayload)          // never installed
			// Unknown future keys inside setup are ignored, not fatal.
			bytes = try Data(contentsOf: URL(fileURLWithPath: config.configPath()))
			let patched = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
				of: #""installed":true"#, with: #""installed":true,"futureKey":1"#)
			try Data(patched.utf8).write(to: URL(fileURLWithPath: config.configPath()))
			#expect(try VMConfig.load(name: "setup-state").setup?.installed == true)
		}
	}

	@Test func newFieldsDefaultAndRoundTrip() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "fields")
			let config = try VMConfig(name: "fields", memorySize: 2048, cpuCount: 2)
			#expect(config.startPolicy == StartPolicy())
			#expect(config.totalRuntimeSeconds == 0)

			config.disks = [VMDisk(kind: .storage("disk", 0), safe: false)]
			config.startPolicy = StartPolicy(windowed: false, safe: true, autostart: true)
			config.totalRuntimeSeconds = 42
			try config.saveVMConfig()

			let back = try VMConfig.load(name: "fields")
			#expect(back.disks.first?.safe == false)
			#expect(back.startPolicy == StartPolicy(windowed: false, safe: true, autostart: true))
			#expect(back.totalRuntimeSeconds == 42)

			let bytes = try Data(contentsOf: URL(fileURLWithPath: config.configPath()))
			#expect(String(decoding: bytes, as: UTF8.self).contains(#""kind""#))
		}
	}
}
