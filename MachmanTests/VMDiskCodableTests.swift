//
//  VMDiskCodableTests.swift
//  MachmanTests
//
//  Persistence-shape tests for the disk and mount config types. Uses plain JSONEncoder/Decoder
//  (the persistence coders), not MachmanWire — these types never cross the wire directly.
//

import Foundation
import Testing
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
	}
}
