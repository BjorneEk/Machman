//
//  KernelClearTests.swift
//  MachmanCoreTests
//
//  vm.kernel.clear (H54, the user's review-4 note): a kernel draft kept after kernel boot was
//  switched off had no way out but deleting each file, deselecting each reference and
//  blanking the command line. One call now removes the draft, the VM's kernel files and their
//  overrides; it refuses while kernel boot reads them, and leaves the boot mode alone (K3).
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (engine config in a redirected library) and loopback (client → socket → server).
struct KernelClearTests {
	// A VM with an owned kernel and initramfs, both selected, a command line and an override
	// on the kernel, kernel boot switched off again.
	private func parkedVM(_ name: String) throws -> (VMConfig, kernel: String, initrd: String) {
		try VMConfig.createNewVMDirectory(name: name)
		let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
		let src = TestEnvironment.scratch + "clear-\(UUID().uuidString).bin"
		try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
		defer { try? FileManager.default.removeItem(atPath: src) }
		let kernel = try KernelStore.promote(
			role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "6.12")
		let initrd = try KernelStore.promote(
			role: .initramfs, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "6.12")
		try cfg.setKernelBoot(enabled: true)
		try cfg.updateKernelSettings(LinuxKernelBoot(
			kernelPath: kernel, initialRamdiskPath: initrd, commandLine: "console=hvc0"))
		try cfg.setKernelOverride(forFileAt: kernel, commandLine: "quiet", enabled: true)
		try cfg.setKernelBoot(enabled: false)
		return (cfg, kernel, initrd)
	}

	@Test("H54: removing kernel settings deletes the owned files, the draft and the overrides")
	func clearRemovesEverything() throws {
		try VMTestDir.withRedirectedDir {
			let (cfg, _, _) = try parkedVM("parked")
			#expect(cfg.ownedKernelFiles().count == 2)
			try cfg.clearKernelSettings()
			for config in [cfg, try VMConfig.load(name: "parked")] {
				#expect(config.boot == .efi)
				#expect(config.kernelSettings == nil)
				#expect(config.kernelOverrides.isEmpty)
				#expect(config.ownedKernelFiles().isEmpty)
			}
			#expect(!FileManager.default.fileExists(atPath: cfg.kernelsDirPath()))
		}
	}

	@Test("H54: removing kernel settings is refused while kernel boot is on")
	func clearRefusedWhileKernelBooting() throws {
		try VMTestDir.withRedirectedDir {
			let (cfg, kernel, _) = try parkedVM("booting")
			try cfg.setKernelBoot(enabled: true)
			let error = try #require(throws: MachmanError.self) { try cfg.clearKernelSettings() }
			#expect(error.code == .invalidState)
			#expect(error.message
				== "Choose another bootloader for booting before removing its kernel settings")
			#expect(cfg.kernelSettings?.kernelPath == kernel)
			#expect(cfg.ownedKernelFiles().count == 2)

			// A boot mode a newer Machman wrote keeps whatever it may need (C11).
			cfg.boot = try JSONDecoder().decode(
				BootConfig.self, from: Data(#"{"future":{"_0":{}}}"#.utf8))
			let newer = try #require(throws: MachmanError.self) { try cfg.clearKernelSettings() }
			#expect(newer.message == BootInfo.newerModeReason)
			#expect(cfg.ownedKernelFiles().count == 2)
		}
	}

	// K3: a macOS VM keeps its kernel files until they are removed, and removing them leaves
	// it a macOS VM.
	@Test("D31: removing a macOS VM's kernel settings keeps it macOS")
	func clearKeepsMacOS() throws {
		try VMTestDir.withRedirectedDir {
			let (cfg, _, _) = try parkedVM("mac")
			let mac = BootConfig.macOS(
				MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
			cfg.boot = mac
			try cfg.saveVMConfig()
			try cfg.clearKernelSettings()
			let reloaded = try VMConfig.load(name: "mac")
			#expect(reloaded.boot == mac)
			#expect(reloaded.kernelSettings == nil)
			#expect(reloaded.ownedKernelFiles().isEmpty)
		}
	}

	@Test("H54: vm.kernel.clear round-trips over the socket") @MainActor
	func clearCrossesTheWire() async throws {
		let socketPath = TestEnvironment.socketPath("mm-kclear")
		var parked = Samples.kernelParkedCommandLineOnly("Lab")
		parked.boot.ownedKernels = Samples.kernelBoot("Lab").boot.ownedKernels
		let stub = StubMachman.serving([parked, Samples.kernelBoot("Booting")])
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "kernel-clear")

		let cleared = try await client.clearKernelSettings(vm: "Lab")
		#expect(cleared.boot.mode == .efi)
		#expect(cleared.boot.kernel == nil)
		#expect(cleared.boot.ownedKernels == nil)
		#expect(stub.calls.contains("clearKernelSettings"))

		// A refusal comes back with its code and sentence.
		let refused = try await #require(throws: MachmanError.self) {
			_ = try await client.clearKernelSettings(vm: "Booting")
		}
		#expect(refused.code == .invalidState)
		#expect(refused.message
			== "Choose another bootloader for Booting before removing its kernel settings")
		await client.disconnect()
	}

	// D31 (review F20): the agent took kernel adds, picks, re-tags and overrides for a macOS
	// VM, whose kept kernel files can only go — every client but the desktop could still add
	// them. Each is refused with one sentence now, on the stub as in the engine (delete and
	// vm.kernel.clear stay: "D31: a macOS VM keeps and lists its kernel files and draft",
	// "D31: removing a macOS VM's kernel settings keeps it macOS").
	@Test("D31: a macOS VM refuses kernel adds, picks, re-tags and overrides")
	@MainActor
	func aMacOSVMRefusesKernelEdits() async throws {
		var engine: LocalMachman?
		var name = ""
		var owned = ""
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			name = vm.config.name
			let src = TestEnvironment.scratch + "mac-edit-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			owned = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: vm.config.kernelsDirPath(),
				tag: "6.12")
			vm.config.boot = .macOS(
				MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
			try vm.config.saveVMConfig()
			engine = LocalMachman(registry: registry)
		}
		var mac = Samples.macOSWithKernelFiles(name)
		mac.boot.ownedKernels?[0].path = owned
		let stub = StubMachman.serving([mac])
		let refusal = "\(name) is a macOS VM \u{2014} its kernel files can only be removed"
		// Every refusal comes before the call touches a file.
		let apis: [any MachmanControlling] = [try #require(engine), stub]
		for api in apis {
			let ops: [(String, () async throws -> Void)] = [
				("promote", {
					_ = try await api.promoteKernelFile(
						vm: name, role: .kernel, sourcePath: "/nowhere/vmlinuz", tag: "6.13")
				}),
				("re-tag", {
					_ = try await api.renameKernelFile(vm: name, path: owned, tag: "6.13")
				}),
				("settings", {
					let settings = KernelSettings(
						kernelPath: owned, initrdPath: nil, commandLine: "")
					try await api.updateKernelSettings(vm: name, settings)
				}),
				("override", {
					_ = try await api.setKernelOverride(
						vm: name, path: owned, commandLine: "quiet", overrideEnabled: true)
				}),
			]
			for (label, op) in ops {
				do {
					try await op()
					Issue.record("\(label) went through on a macOS VM (\(type(of: api)))")
				} catch let error as MachmanError {
					#expect(error.code == .invalidState, "\(label): \(error.code)")
					#expect(error.message == refusal, "\(label) (\(type(of: api)))")
				}
			}
		}
	}
}
