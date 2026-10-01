//
//  GuestReportMarkerTests.swift
//  MachmanTests
//
//  PR4/C7: a guest report carries the MARKER of the identity it was written for, and
//  apply() ignores one naming another identity — a source VM's leftover that traveled with
//  a copy, or a cloned guest's boot hook still running the source's script.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct GuestReportMarkerTests {
	@Test @MainActor func aReportForAnotherIdentityIsIgnored() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "copy")
			let vm = try VMConfig(name: "copy", memorySize: 1 << 30, cpuCount: 2)
			let own = try SSHSetupInstaller.marker(for: vm)   // mints the identity file

			let foreign = try GuestReport.parse("""
				MARKER=machman-000000000000
				HOSTNAME=src-box
				IP=192.168.64.9
				HOST_KEY=ssh-ed25519 AAAA src
				SCRIPT_VERSION=4
				STATUS=ok
				""").apply(to: vm, stampedAt: Date())
			#expect(!foreign.any)
			#expect(vm.ssh?.guestHostname == nil)
			#expect(vm.ssh?.lastAddress == nil)
			#expect(vm.setup == nil)

			let mine = try GuestReport.parse("""
				MARKER=\(own)
				HOSTNAME=copy-box
				SCRIPT_VERSION=4
				STATUS=ok
				""").apply(to: vm, stampedAt: Date())
			#expect(mine.ssh && mine.setup)
			#expect(vm.ssh?.guestHostname == "copy-box")
			#expect(vm.setup?.installed == true)
		}
	}

	// A VM with no identity file yet has served no payload: every marker is another's.
	@Test @MainActor func aVMWithoutAnIdentityTakesNoMarkedReport() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "fresh")
			let vm = try VMConfig(name: "fresh", memorySize: 1 << 30, cpuCount: 2)
			#expect(SSHSetupInstaller.existingMarker(for: vm) == nil)
			#expect(!(try GuestReport.parse("MARKER=machman-abc\nHOSTNAME=x")
				.apply(to: vm, stampedAt: Date()).any))
		}
	}

	// The uninstall report is gated too: another identity's uninstall must not wipe this
	// VM's learned state.
	@Test @MainActor func anotherIdentitysUninstallChangesNothing() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept")
			let vm = try VMConfig(name: "kept", memorySize: 1 << 30, cpuCount: 2)
			let own = try SSHSetupInstaller.marker(for: vm)
			try GuestReport.parse("MARKER=\(own)\nUSER=admin\nSCRIPT_VERSION=4\nSTATUS=ok")
				.apply(to: vm, stampedAt: Date())
			#expect(!(try GuestReport.parse("MARKER=machman-000000000000\nUNINSTALLED=1")
				.apply(to: vm, stampedAt: Date()).any))
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.setup?.installed == true)
		}
	}
}
