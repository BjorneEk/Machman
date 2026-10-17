//
//  StubParityTests.swift
//  MachmanCoreTests
//
//  StubMachman against the engine (Q29): the view-model tests drive the stub, so where the
//  stub's mutators disagree with what the daemon serves, a desktop bug that lives in that
//  state can't be reproduced headless (review 4 found the stuck kernel sections that way).
//  Each case runs the same steps on a real VMConfig and on the stub and compares what both
//  serve for the boot.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// L1: unit (engine config in a redirected library, the stub in memory).
@MainActor
struct StubParityTests {
	struct Served: Equatable, CustomStringConvertible {
		let mode: BootInfo.Mode
		let kernel: KernelSettings?
		init(_ boot: BootInfo) {
			mode = boot.mode
			kernel = boot.kernel
		}
		var description: String { "\(mode) \(kernel.map { "\($0)" } ?? "no draft")" }
	}

	@Test("Q29: the stub's kernel-boot switch serves what the engine serves")
	func kernelBootSwitch() async throws {
		let steps = [true, false, true, false]
		var engine: [Served] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			for enabled in steps {
				try vm.config.setKernelBoot(enabled: enabled)
				engine.append(Served(api.info(for: vm).boot))
			}
		}
		let stub = StubMachman.serving([StubMachman.makeInfo("Parity")])
		var served: [Served] = []
		for enabled in steps {
			try await stub.setKernelBoot(vm: "Parity", enabled: enabled)
			served.append(Served(try await stub.vm(named: "Parity").boot))
		}
		#expect(served == engine)
	}

	// N3: a parked draft emptied by a settings write goes; one that keeps a command line stays.
	@Test("Q29: an emptied parked draft goes on the stub as on the engine")
	func emptiedParkedDraft() async throws {
		let line = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "quiet")
		let empty = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		enum Step { case boot(Bool), write(KernelSettings) }
		let steps: [Step] = [.boot(true), .write(line), .boot(false), .write(empty)]
		var engine: [Served] = []
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			for step in steps {
				switch step {
				case .boot(let enabled):
					try vm.config.setKernelBoot(enabled: enabled)
				case .write(let settings):
					try vm.config.updateKernelSettings(LinuxKernelBoot(
						kernelPath: settings.kernelPath, initialRamdiskPath: settings.initrdPath,
						commandLine: settings.commandLine))
				}
				engine.append(Served(api.info(for: vm).boot))
			}
		}
		let stub = StubMachman.serving([StubMachman.makeInfo("Parity")])
		var served: [Served] = []
		for step in steps {
			switch step {
			case .boot(let enabled): try await stub.setKernelBoot(vm: "Parity", enabled: enabled)
			case .write(let settings): try await stub.updateKernelSettings(vm: "Parity", settings)
			}
			served.append(Served(try await stub.vm(named: "Parity").boot))
		}
		#expect(served == engine)
		#expect(served.last?.kernel == nil)
	}

	@Test("Q29: the stub's kernel delete clears the field that named the file, like the engine")
	func kernelDeleteClearsTheReference() async throws {
		var engine: Served?
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			let vm = try registry.create()
			let api = LocalMachman(registry: registry)
			let kernelsDir = vm.config.kernelsDirPath()
			let path = kernelsDir + "/kernel/v1/vmlinuz"
			try FileManager.default.createDirectory(
				atPath: kernelsDir + "/kernel/v1", withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: path))
			try vm.config.setKernelBoot(enabled: true)
			try vm.config.updateKernelSettings(LinuxKernelBoot(
				kernelPath: path, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			// LocalMachman.deleteKernelFile's config steps, synchronously.
			try KernelStore.delete(path: path, kernelsDir: kernelsDir)
			try vm.config.clearKernelReference(to: path)
			engine = Served(api.info(for: vm).boot)
		}
		let path = "/vm/Parity/kernels/kernel/v1/vmlinuz"
		var info = StubMachman.makeInfo("Parity")
		info.boot = BootInfo(
			mode: .linuxKernel,
			kernel: KernelSettings(kernelPath: path, initrdPath: nil, commandLine: "console=hvc0"),
			macInstallState: nil, minCPUCount: nil, minMemoryBytes: nil,
			ownedKernels: [OwnedKernelFile(role: .kernel, tag: "v1", fileName: "vmlinuz",
				path: path)])
		let stub = StubMachman.serving([info])
		let after = try await stub.deleteKernelFile(vm: "Parity", path: path)
		#expect(Served(after.boot) == engine)
	}
}
