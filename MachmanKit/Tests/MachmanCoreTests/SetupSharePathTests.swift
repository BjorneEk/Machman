//
//  SetupSharePathTests.swift
//  MachmanTests
//
//  C26: ssh.setupSharePath, the folder the BSD guide's by-hand sshfs mount names, was the
//  VM's own <vmdir>/share — a path carrying the VM's name, which the copied command had to
//  quote and a rename stranded. Once a start has pointed it, the VM is served its rename-
//  stable link in the library instead (<library>/.machman-shares/<marker>, C16's link).
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct SetupSharePathTests {
	private func resolved(_ path: String) -> String {
		URL(fileURLWithPath: path).resolvingSymlinksInPath().path
	}

	@Test @MainActor func theServedSharePathIsTheRenameStableLink() throws {
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			try api.attachDevice(.guestSetup, to: vm)
			let share = GuestInstallerWriter.payloadRoot(for: vm.config).path
			// Before its first start there is no link: the share itself.
			#expect(api.info(for: vm).ssh?.setupSharePath == share)

			_ = try GuestSetupInstaller.writePayload(for: vm.config)   // what a start does
			let served = try #require(api.info(for: vm).ssh?.setupSharePath)
			#expect(served.contains("/\(GuestSetupInstaller.shareLinksDirectoryName)/machman-"))
			#expect(!served.contains(vm.name))
			#expect(resolved(served) == resolved(share))
		}
	}
}
