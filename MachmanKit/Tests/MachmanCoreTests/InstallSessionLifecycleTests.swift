//
//  InstallSessionLifecycleTests.swift
//  MachmanTests
//
//  A macOS install session's life beside the registry: one install at a time (E15b), and
//  no folder move under a running one. The installer itself never runs — an injected
//  runner holds the session "installing" until the test opens its gate, then ends it the
//  way a user cancel does (no failure log).
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
private final class Gate {
	var open = false

	// A runner that installs nothing: it waits for the gate, then cancels quietly.
	var runner: InstallSession.Runner {
		{ [self] _, _ in
			while !open { try await Task.sleep(for: .milliseconds(10)) }
			throw CocoaError(.userCancelled)
		}
	}
}

struct InstallSessionLifecycleTests {
	private static let ipsw = InstallSource(kind: .ipsw, path: "/nonexistent.ipsw")

	private func makeConfig(name: String) throws -> VMConfig {
		let config = try JSONDecoder().decode(
			VMConfig.self,
			from: Data(#"{"name":"seed","memorySize":2048,"cpuCount":2,"created":1000}"#.utf8))
		config.name = name
		return config
	}

	@Test @MainActor func aSecondInstallStartIsRefused() async throws {
		let gate = Gate()
		let session = InstallSession(
			config: try makeConfig(name: "mac"), events: EventBus(),
			isVMRunning: { false }, run: gate.runner)
		try session.startInstall(source: Self.ipsw)
		#expect(session.isInstalling)

		let error = try #require(throws: MachmanError.self) {
			try session.startInstall(source: Self.ipsw)
		}
		#expect(error.code == .invalidState)
		#expect(session.isInstalling)   // the first install is untouched

		gate.open = true
		#expect(await eventually(timeout: .seconds(10)) { !session.isInstalling })
	}

	@Test @MainActor func renameRefusesWhileInstalling() throws {
		let gate = Gate()
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			_ = try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2)
			let registry = VMRegistry()
			registry.installRunner = gate.runner
			let vm = try #require(registry.vm(named: "mac"))
			try registry.installSession(for: vm).startInstall(source: Self.ipsw)
			defer { gate.open = true }

			let error = try #require(throws: MachmanError.self) {
				try registry.rename(vm, to: "other")
			}
			#expect(error.code == .invalidState)
			#expect(FileManager.default.fileExists(atPath: machmanVMDir + "/mac/config"))
			#expect(registry.vm(named: "mac") === vm)
		}
	}

	// E4: a session made before a run holds the pre-run config; after the vmhost exits the
	// daemon reloads, and the next install must save through the FRESH config.
	@Test @MainActor func reloadGivesTheNextInstallAFreshConfig() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			let cfg = try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2)
			cfg.boot = .macOS(MacOSBoot(
				installState: .failed("x"), minimumCPUCount: 2, minimumMemorySize: 2048))
			try cfg.saveVMConfig()
			let registry = VMRegistry()
			let s1 = registry.installSession(for: try #require(registry.vm(named: "mac")))
			// The run (a vmhost) persists its own state behind the daemon's copy.
			let ran = try VMConfig.load(name: "mac")
			ran.cpuCount = 3
			try ran.saveVMConfig()

			registry.reload(name: "mac")

			let vm2 = try #require(registry.vm(named: "mac"))
			let s2 = registry.installSession(for: vm2)
			#expect(s2 !== s1)
			#expect(s2.config === vm2.config)
			#expect(s2.config.cpuCount == 3)
		}
	}

	@Test @MainActor func anInstallingSessionKeepsItsConfigAcrossAReload() throws {
		let gate = Gate()
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			_ = try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2)
			let registry = VMRegistry()
			registry.installRunner = gate.runner
			let s1 = registry.installSession(for: try #require(registry.vm(named: "mac")))
			try s1.startInstall(source: Self.ipsw)
			defer { gate.open = true }

			registry.reload(name: "mac")

			let vm = try #require(registry.vm(named: "mac"))
			#expect(vm.config === s1.config)
			#expect(registry.installSession(for: vm) === s1)
		}
	}
}
