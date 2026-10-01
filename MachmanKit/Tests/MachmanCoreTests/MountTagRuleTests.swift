//
//  MountTagRuleTests.swift
//  MachmanCoreTests
//
//  D17/S17, the host half: a mount tag is a directory name inside the VM's one share, so it
//  passes the mount-tag rule and VZ's share-name check at add and rename. "a/b" used to
//  fail only at the next start, a tab or line break corrupted mounts.list, and "*.txt"
//  globbed in the guest.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

@MainActor
struct MountTagRuleTests {
	private func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		return try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
	}

	@Test func tagsFollowTheShareNameRules() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("tags")
			for bad in ["a/b", ".", "..", ".config", "a\tb", "a\nb", "*.txt", "a:b", "a?b",
				String(repeating: "x", count: 256)] {
				let error = try #require(throws: MachmanError.self, "\(bad)") {
					try vm.addMountPoint(HostMountPoint(path: "/tmp", tag: bad))
				}
				#expect(error.code == .invalidArgument, "\(bad)")
			}
			for (index, fine) in ["my docs", "日本語", "a[b]", "~x"].enumerated() {
				try vm.addMountPoint(HostMountPoint(path: "/tmp/\(index)", tag: fine))
			}
			#expect(vm.mountPoints.map(\.tag) == ["my docs", "日本語", "a[b]", "~x"])
			#expect(throws: MachmanError.self) {
				try vm.setMountTag(id: vm.mountPoints[0].id.uuidString, tag: "a\tb")
			}
			_ = vm.directoryShareDeviceConfig(mainTag: "host-share")   // must not trap
		}
	}

	@Test func mountsListSkipsRowsThatWouldBreakIt() throws {
		try VMTestDir.withRedirectedDir {
			let vm = try makeVM("rows")
			try vm.addMountPoint(HostMountPoint(
				path: "/Users/x/My Docs", tag: "docs", kind: MountKind.sshfs))
			// Stored before the rule existed: validate at entry, never at load.
			vm.mountPoints.append(HostMountPoint(
				path: "/tmp/x", tag: "a\tb", kind: MountKind.sshfs))
			let files = try GuestSetupInstaller.extraFiles(for: vm)
			let list = try #require(files[GuestSetupInstallerInfo.mountsFileName] ?? nil)
			#expect(String(decoding: list, as: UTF8.self) == "sshfs\tdocs\t/Users/x/My Docs\n")
		}
	}
}
