//
//  MacInstallRetryTests.swift
//  MachmanTests
//
//  E24: a failed or cancelled macOS install leaves mac_aux.img behind, so the retry must
//  create the aux storage over it — and, with that, an install must never start on a Mac
//  that is installed. VZ can't run headless: the options value is pinned, the refusal is
//  exercised (it throws before any download or file write).
//

import Testing
import Foundation
import Virtualization
import MachmanAPI
@testable import MachmanCore

@MainActor
struct MacInstallRetryTests {
	@Test func auxStorageCreationOverwritesALeftover() {
		#expect(VMConfig.macAuxStorageCreationOptions.contains(.allowOverwrite))
	}

	@Test func anInstalledMacRefusesAnInstall() async throws {
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"mac","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.boot = .macOS(MacOSBoot(
			installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
		let installer = MacInstaller(config: config)
		let error = await #expect(throws: MachmanError.self) {
			try await installer.install(
				source: .localIPSW(URL(fileURLWithPath: "/nonexistent/restore.ipsw")))
		}
		#expect(error?.code == .invalidState)
		#expect(config.boot.isMacInstalled)
	}

	// The API entry refuses before any session phase changes.
	@Test func theAPIRefusesAnInstallOnAnInstalledMac() async throws {
		var api: LocalMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			let config = try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2)
			config.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
			try config.saveVMConfig()
			api = LocalMachman(registry: VMRegistry())
		}
		// A local image that doesn't exist: even unguarded, nothing would be downloaded.
		let error = await #expect(throws: MachmanError.self) {
			try await api.startMacInstall(vm: "mac", source: .ipsw("/nonexistent/restore.ipsw"))
		}
		#expect(error?.code == .invalidState)
		#expect(try await api.macInstallPhase(vm: "mac").kind == .installed)
	}
}
