//
//  StartPolicySafetyTests.swift
//  MachmanTests
//
//  Persistence behavior of the start-policy and safety setters.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct StartPolicySafetyTests {
	@Test @MainActor func setStartPolicyPersistsAcrossLoad() throws {
		try VMTestDir.withRedirectedDir {
			let name = "policy-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)

			let policy = StartPolicy(windowed: false, safe: false, autostart: true)
			try cfg.setStartPolicy(policy)
			#expect(try VMConfig.load(name: name).startPolicy == policy)
		}
	}

	@Test @MainActor func setSafetyFlipsFlagsAndPersists() throws {
		try VMTestDir.withRedirectedDir {
			let name = "safety-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.disks = [
				VMDisk(kind: .storage("disk", 0)),
				VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/d.iso"))),
			]
			try cfg.addMountPoint(HostMountPoint(path: "/Users/x/share", tag: "share"))
			let mountID = try #require(cfg.mountPoints.first?.id)

			try cfg.setSafety(
				disks: ["storage:disk": false], mounts: [mountID.uuidString: false])

			let back = try VMConfig.load(name: name)
			#expect(back.disks.first(where: { $0.id == "storage:disk" })?.safe == false)
			#expect(back.disks.first(where: { $0.id.hasPrefix("iso:") })?.safe == true)
			#expect(back.mountPoints.first?.safe == false)
		}
	}

	@Test @MainActor func setSafetyUnknownIDWritesNothing() throws {
		try VMTestDir.withRedirectedDir {
			let name = "safety-atomic"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.disks = [VMDisk(kind: .storage("disk", 0))]
			try cfg.saveVMConfig()

			#expect(throws: MachmanError.self) {
				try cfg.setSafety(
					disks: ["storage:disk": false, "storage:bogus": false], mounts: [:])
			}
			// All-or-nothing: the valid entry did not apply either.
			#expect(try VMConfig.load(name: name).disks.first?.safe == true)
		}
	}
}
