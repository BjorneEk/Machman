//
//  PromoteRestrictedVMTests.swift
//  MachmanTests
//
//  The vmhost half of vm.safeSave: a restricted registry pointed at a shadow run root
//  renames its VM into the library and re-keys itself. The redirected machmanVMDir plays the
//  run root; a sibling tmp dir plays the library; a bare VMRuntime (no VZ) marks the VM
//  "running" for the guard.
//

import Testing
import Foundation
import Virtualization
import MachmanAPI
@testable import MachmanCore

struct PromoteRestrictedVMTests {
	// Runs inside the redirect: machmanVMDir = run root. Returns (registry, library).
	@MainActor
	private func makeSafeHost(
		promotionLibrary: Bool = true, running: Bool = true, macOS: Bool = false
	) throws -> (VMRegistry, String) {
		let library = machmanVMDir + "-lib"
		try FileManager.default.createDirectory(
			atPath: library, withIntermediateDirectories: true)
		try VMConfig.createNewVMDirectory(name: "alpha")
		let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
		cfg.macAddress = "aa:bb:cc:dd:ee:99"
		if macOS {
			cfg.boot = .macOS(MacOSBoot(
				installState: .installed, minimumCPUCount: 2, minimumMemorySize: 2048))
		}
		try cfg.saveVMConfig()
		try Data("vmid".utf8)
			.write(to: URL(fileURLWithPath: machmanVMDir + "/alpha/vm_identifier"))
		let registry = VMRegistry(
			only: "alpha", promotionLibrary: promotionLibrary ? library : nil)
		if running, let vm = registry.vm(named: "alpha") {
			vm.runtime = VMRuntime(config: vm.config, events: registry.events)
		}
		return (registry, library)
	}

	@Test @MainActor func promotionMovesRekeysAndMintsFreshIdentity() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let runRoot = machmanVMDir
			let before = Date()

			let promoted = try registry.promoteRestrictedVM(to: "kept")

			let fm = FileManager.default
			#expect(fm.fileExists(atPath: library + "/kept/config"))
			#expect(!fm.fileExists(atPath: runRoot))               // run root fully gone
			#expect(machmanVMDir == library)                       // global re-pointed
			#expect(registry.restrictedName == "kept")
			#expect(registry.vm(named: "kept") === promoted)
			#expect(registry.vm(named: "alpha") == nil)
			#expect(promoted.config.name == "kept")

			let saved = try JSONDecoder().decode(
				VMConfig.self,
				from: Data(contentsOf: URL(fileURLWithPath: library + "/kept/config")))
			#expect(saved.name == "kept")
			#expect(saved.macAddress != "aa:bb:cc:dd:ee:99")       // fresh MAC persisted
			#expect(saved.created >= before)                       // a new VM, born now
			#expect(saved.totalRuntimeSeconds == 0)
			#expect(!fm.fileExists(atPath: library + "/kept/vm_identifier"))
		}
	}

	@Test @MainActor func promotionMintsAFreshMacMachineID() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(macOS: true)
			defer { try? FileManager.default.removeItem(atPath: library) }
			let sourceID = VZMacMachineIdentifier().dataRepresentation
			try sourceID.write(
				to: URL(fileURLWithPath: machmanVMDir + "/alpha/mac_machine_id"))

			_ = try registry.promoteRestrictedVM(to: "kept")

			let newID = try Data(
				contentsOf: URL(fileURLWithPath: library + "/kept/mac_machine_id"))
			#expect(newID != sourceID)
			#expect(VZMacMachineIdentifier(dataRepresentation: newID) != nil)
		}
	}

	// C1: the shadow's owned kernel paths point into the run root, which promotion moves
	// (then deletes) — the promoted config must point into the library.
	@Test @MainActor func promotionRepointsOwnedKernelPaths() throws {
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			let vm = try #require(registry.vm(named: "alpha"))
			let kernelDir = machmanVMDir + "/alpha/kernels/kernel/v1"
			try FileManager.default.createDirectory(
				atPath: kernelDir, withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: kernelDir + "/vmlinuz"))
			let settings = LinuxKernelBoot(
				kernelPath: kernelDir + "/vmlinuz", initialRamdiskPath: nil,
				commandLine: "console=hvc0")
			vm.config.kernelSettings = settings
			vm.config.boot = .linuxKernel(settings)
			try vm.config.saveVMConfig()

			_ = try registry.promoteRestrictedVM(to: "kept")

			let moved = library + "/kept/kernels/kernel/v1/vmlinuz"
			let saved = try JSONDecoder().decode(
				VMConfig.self,
				from: Data(contentsOf: URL(fileURLWithPath: library + "/kept/config")))
			#expect(saved.kernelSettings?.kernelPath == moved)
			guard case .linuxKernel(let live) = saved.boot else {
				Issue.record("expected a kernel boot")
				return
			}
			#expect(live.kernelPath == moved)
			#expect(FileManager.default.fileExists(atPath: moved))
		}
	}

	@Test @MainActor func promotionRefusals() throws {
		// No promotion library (an unsafe or launchd vmhost): refused.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(promotionLibrary: false)
			defer { try? FileManager.default.removeItem(atPath: library) }
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
		}
		// Destination taken: refused, nothing moved.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost()
			defer { try? FileManager.default.removeItem(atPath: library) }
			try FileManager.default.createDirectory(
				atPath: library + "/kept", withIntermediateDirectories: true)
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
			#expect(FileManager.default.fileExists(atPath: machmanVMDir + "/alpha/config"))
		}
		// The safe run already ended (no runtime): refused.
		try VMTestDir.withRedirectedDir {
			let (registry, library) = try makeSafeHost(running: false)
			defer { try? FileManager.default.removeItem(atPath: library) }
			#expect(throws: MachmanError.self) {
				try registry.promoteRestrictedVM(to: "kept")
			}
		}
	}
}
