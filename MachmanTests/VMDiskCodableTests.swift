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
