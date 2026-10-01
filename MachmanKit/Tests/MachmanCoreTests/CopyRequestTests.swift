//
//  CopyRequestTests.swift
//  MachmanTests
//
//  What vm.copy hands the copier (LocalMachman.copyRequest): disks by policy, and the
//  mounts the client chose (C11 — it used to pass nil, so the choice never arrived).
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

@MainActor
struct CopyRequestTests {
	private func config(mounts: [HostMountPoint]) throws -> VMConfig {
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"src","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.disks = [
			VMDisk(kind: .storage("system", 0)), VMDisk(kind: .storage("scratch", 0)),
			VMDisk(kind: .iso(URL(fileURLWithPath: "/isos/a.iso"))),
		]
		config.mountPoints = mounts
		return config
	}

	@Test func chosenMountsAndDisksReachTheCopier() throws {
		let keep = HostMountPoint(path: "/Users/x/src", tag: "src")
		let drop = HostMountPoint(path: "/Users/x/notes", tag: "notes")
		let request = LocalMachman.copyRequest(
			from: try config(mounts: [keep, drop]), sourceDir: "/lib/src",
			destinationParent: "/lib", newName: "dup", diskIDs: ["storage:system"],
			mountIDs: [keep.id.uuidString], regenerateMAC: true)
		#expect(request.includedMountIDs == [keep.id.uuidString])
		#expect(request.diskPolicies["storage:system"] == .clone)
		#expect(request.diskPolicies["storage:scratch"] == .omit)
		#expect(request.diskPolicies["iso:file:///isos/a.iso"] == .reference)
	}

	@Test func noChoiceCarriesEveryMount() throws {
		let request = LocalMachman.copyRequest(
			from: try config(mounts: [HostMountPoint(path: "/Users/x/src", tag: "src")]),
			sourceDir: "/lib/src", destinationParent: "/lib", newName: "dup",
			diskIDs: nil, mountIDs: nil, regenerateMAC: true)
		#expect(request.includedMountIDs == nil)
		#expect(request.diskPolicies["storage:scratch"] == .clone)
	}
}
